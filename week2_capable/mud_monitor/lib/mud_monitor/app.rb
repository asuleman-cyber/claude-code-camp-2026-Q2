require "sinatra/base"
require "time"

require_relative "session"
require_relative "ansi"
require_relative "manager_log"
require_relative "telnet_log"

module MudMonitor
  # Unified observability for a boukensha+mud_manager run: agent sessions
  # (forked from week1_baseline/log_viz), the mud_manager command log, and
  # the raw telnet feed — one app instead of three, per
  # docs/plans/week_2/mud_monitor.md's stated goal. Scoped down from that
  # doc's Rails+React design to Sinatra+ERB (see week2_capable/README.md
  # Phase B) and to "live polling" (meta-refresh) rather than SSE.
  class App < Sinatra::Base
    set :root, File.expand_path("../..", __dir__)
    # __dir__ is .../week2_capable/mud_monitor/lib/mud_monitor — four levels
    # up reaches the repo root: lib/mud_monitor -> lib -> mud_monitor ->
    # week2_capable -> repo root.
    set :sessions_dir, ENV.fetch("MUD_MONITOR_SESSIONS_DIR") {
      File.expand_path("../../../../.boukensha/sessions", __dir__)
    }
    set :manager_dir, ENV["MUD_MONITOR_MANAGER_DIR"] || File.expand_path("../../../../.boukensha/manager", __dir__)
    set :telnet_dir,  ENV["MUD_MONITOR_TELNET_DIR"]  || File.expand_path("../../../../.boukensha/telnet", __dir__)

    PER_PAGE = 25

    helpers do
      def manager_store = @manager_store ||= ManagerLogStore.new(settings.manager_dir)
      def telnet_store  = @telnet_store  ||= TelnetLogStore.new(settings.telnet_dir)

      def session_paths
        Dir.glob(File.join(settings.sessions_dir, "*.jsonl")).sort.reverse
      end

      # HTML-attribute-safe escaping (covers quotes, unlike Ansi.escape_html)
      # for reflecting request params like the search box's `q` back into HTML.
      def h(text)
        Rack::Utils.escape_html(text.to_s)
      end

      # ---- index page: filter / sort / paginate ---------------------------
      def task_text(session)
        names = session.task_names
        names.any? ? names.join(" ") : session.task.to_s
      end

      def filtered_sessions(sessions)
        q     = params[:q].to_s.strip.downcase
        model = params[:model].to_s.strip

        sessions = sessions.select { |s| s.id.downcase.include?(q) || task_text(s).downcase.include?(q) } unless q.empty?
        sessions = sessions.select { |s| s.response_models.include?(model) } unless model.empty?
        sessions
      end

      def current_sort_key
        %w[cost tokens iterations].include?(params[:sort]) ? params[:sort] : "started_at"
      end

      def current_dir
        params[:dir] == "asc" ? "asc" : "desc"
      end

      def sort_sessions(sessions)
        sorted = case current_sort_key
                 when "cost"       then sessions.sort_by { |s| s.estimated_cost || -1 }
                 when "tokens"     then sessions.sort_by { |s| s.total_input_tokens + s.total_output_tokens }
                 when "iterations" then sessions.sort_by { |s| s.iteration_count }
                 else                   sessions.sort_by { |s| s.started_at.to_s }
                 end
        current_dir == "asc" ? sorted : sorted.reverse
      end

      def paginate(items)
        total_pages = [(items.length.to_f / PER_PAGE).ceil, 1].max
        page        = params[:page].to_i
        page        = 1 if page < 1
        page        = total_pages if page > total_pages
        offset      = (page - 1) * PER_PAGE
        { items: items.slice(offset, PER_PAGE) || [], page: page, total_pages: total_pages }
      end

      def model_options(sessions)
        sessions.flat_map(&:response_models).uniq.sort
      end

      # Builds a "/?..." link preserving the current q/model/sort/dir/page,
      # overridden by `overrides` (a nil value removes that key).
      def query_merge(overrides)
        current = { "q" => params[:q], "model" => params[:model], "sort" => params[:sort],
                    "dir" => params[:dir], "page" => params[:page] }
        merged  = current.merge(overrides.transform_keys(&:to_s)).reject { |_, v| v.nil? || v.to_s.empty? }
        query   = Rack::Utils.build_query(merged)
        query.empty? ? request.path_info : "#{request.path_info}?#{query}"
      end

      def sort_link(label, key)
        active   = current_sort_key == key
        next_dir = active && current_dir == "desc" ? "asc" : "desc"
        arrow    = active ? (current_dir == "asc" ? " &uarr;" : " &darr;") : ""
        %(<a href="#{query_merge("sort" => key, "dir" => next_dir, "page" => nil)}">#{label}#{arrow}</a>)
      end

      def format_time(iso)
        return "?" unless iso

        Time.parse(iso).strftime("%Y-%m-%d %H:%M:%S %z")
      rescue ArgumentError
        iso
      end

      # Clock-only, for the per-entry timing gutter (the date is already in
      # the page header — repeating it on every row is noise).
      def fmt_clock(iso)
        return nil unless iso

        Time.parse(iso).strftime("%H:%M:%S.%L")
      rescue ArgumentError
        nil
      end

      def truncate(text, length = 100)
        flat = text.to_s.gsub(/\s+/, " ").strip
        flat.length > length ? "#{flat[0, length]}…" : flat
      end

      def format_args(args)
        return "" if args.nil? || args.empty?

        args.map { |k, v| "#{k}: #{v.inspect}" }.join(", ")
      end

      def ansi_html(text)
        Ansi.to_html(text)
      end

      def text_html(text)
        Ansi.escape_html(text)
      end

      def fmt_tokens(n)
        n = n.to_i
        n >= 1000 ? format("%.1fk", n / 1000.0) : n.to_s
      end

      def pct(used, max)
        max.to_i.positive? ? [(used.to_f / max.to_i * 100).round, 100].min : 0
      end

      def pct_raw(used, max)
        max.to_i.positive? ? (used.to_f / max.to_i * 100).round : 0
      end

      def progress_bar(used, max, label:, danger: false)
        width = pct(used, max)
        klass = danger ? "bar-fill danger" : "bar-fill"
        <<~HTML
          <div class="budget">
            <div class="budget-label">#{label}</div>
            <div class="bar"><div class="#{klass}" style="width: #{width}%"></div></div>
          </div>
        HTML
      end

      def fmt_cost(n)
        n.nil? ? "&mdash;" : format("$%.4f", n)
      end

      def fmt_cost_cell(cost, known: true)
        return "&mdash;" if cost.nil? || !known

        fmt_cost(cost)
      end

      # Duration/gap pill. `coarse: true` (pre-ms-timestamp logs) renders
      # "~1s" muted rather than a falsely precise "0ms" — see
      # Session#timing_source.
      def fmt_dt(ms, coarse: false)
        return "&mdash;" if ms.nil?
        return %(<span class="dt-pill dt-coarse">~#{[(ms / 1000.0).round, 1].max}s</span>) if coarse

        text = ms < 1000 ? "#{ms}ms" : format("%.1fs", ms / 1000.0)
        klass = ms >= 5000 ? "dt-pill dt-slow" : "dt-pill"
        %(<span class="#{klass}">+#{text}</span>)
      end

      def live_badge(live)
        return "" unless live

        %(<span class="live-badge">&#9679; live</span>)
      end

      # Sinatra's dev-mode HostAuthorization aside, a live page just needs to
      # reload itself periodically — no JS, matching this app's zero-JS
      # style. `content` is seconds between reloads.
      def live_refresh_tag(live, content: 3)
        return "" unless live

        %(<meta http-equiv="refresh" content="#{content}">)
      end

      def ctx_chip(usage, running, context_window:, max_turn_tokens:, model: nil, provider: nil, cost_usd: nil)
        return "" unless usage

        input = usage["input_tokens"].to_i
        out   = usage["output_tokens"].to_i
        cache = usage["cache_read_input_tokens"].to_i

        parts = []
        if max_turn_tokens.to_i.positive?
          danger = running.to_i > max_turn_tokens.to_i ? " danger" : ""
          parts << %(<span class="ctx-turn#{danger}">turn #{fmt_tokens(running)}/#{fmt_tokens(max_turn_tokens)}</span>)
          parts << %(<span class="ctx-bar"><span class="ctx-bar-fill#{danger}" style="width: #{pct(running, max_turn_tokens)}%"></span></span>)
        end
        parts << %(<span class="ctx-amt">ctx #{fmt_tokens(input)}</span>)
        if context_window.to_i.positive?
          parts << %(<span class="ctx-mini"><span class="ctx-mini-fill" style="width: #{pct(input, context_window)}%"></span></span>)
        end
        parts << %(<span class="ctx-out">+#{fmt_tokens(out)} out</span>)
        parts << %(<span class="ctx-cache">cached #{fmt_tokens(cache)}</span>) if cache.positive?
        parts << %(<span class="ctx-cost">#{fmt_cost(cost_usd)}</span>) unless cost_usd.nil?
        parts << %(<span class="ctx-model">#{[provider, model].compact.join(" / ")}</span>) if provider || model

        %(<span class="ctx-chip">#{parts.join("\n")}</span>)
      end

      # Inline SVG sparkline of per-iteration input_tokens across the session.
      def sparkline(points, max:, width: 640, height: 48)
        return "" if points.length < 2

        max = 1 if max.to_i < 1
        step = width.to_f / (points.length - 1)

        coords = points.each_with_index.map do |p, i|
          x = (i * step).round(1)
          y = (height - (p.input.to_f / max * (height - 4)) - 2).round(1)
          "#{x},#{y}"
        end.join(" ")

        boundaries = points.each_with_index.select { |p, i| i.positive? && p.iteration == 1 }
        rules = boundaries.map do |_p, i|
          x = (i * step).round(1)
          %(<line class="spark-turn" x1="#{x}" y1="0" x2="#{x}" y2="#{height}"/>)
        end.join

        <<~SVG
          <svg class="spark" viewBox="0 0 #{width} #{height}" preserveAspectRatio="none" role="img" aria-label="input tokens per iteration">
            #{rules}
            <polyline class="spark-line" points="#{coords}"/>
          </svg>
        SVG
      end
    end

    get "/" do
      all_sessions = session_paths.map { |path| Session.load(path, light: true) }
      @models      = model_options(all_sessions)

      filtered      = sort_sessions(filtered_sessions(all_sessions))
      @total        = all_sessions.length
      @total_matches = filtered.length

      page_data    = paginate(filtered)
      @sessions    = page_data[:items]
      @page        = page_data[:page]
      @total_pages = page_data[:total_pages]
      erb :index
    end

    get "/sessions/:id" do
      id   = File.basename(params[:id])
      path = File.join(settings.sessions_dir, "#{id}.jsonl")
      halt 404, "Session not found: #{id}" unless File.file?(path)

      @session = Session.load(path)
      @live    = @session.live? && params[:live] != "0"
      erb :session
    end

    get "/manager" do
      @dates   = manager_store.dates
      @date    = params[:date] if @dates.include?(params[:date])
      @entries = manager_store.recent(date: @date)
      @live    = manager_store.live?(date: @date) && params[:live] != "0"
      erb :manager
    end

    get "/telnet" do
      @dates   = telnet_store.dates
      @date    = params[:date] if @dates.include?(params[:date])
      @dir     = %w[in out].include?(params[:dir]) ? params[:dir] : nil
      entries  = telnet_store.recent(date: @date)
      entries  = entries.select { |e| e.dir == @dir } if @dir
      @entries = entries
      @live    = telnet_store.live?(date: @date) && params[:live] != "0"
      erb :telnet
    end
  end
end
