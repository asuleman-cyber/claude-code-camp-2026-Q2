require "sinatra/base"
require "time"

require_relative "session"
require_relative "ansi"

module LogViz
  class App < Sinatra::Base
    set :root, File.expand_path("../..", __dir__)
    set :sessions_dir, ENV.fetch("LOG_VIZ_SESSIONS_DIR") {
      File.expand_path("../../../../.boukensha/sessions", __dir__)
    }

    PER_PAGE = 25

    helpers do
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

      def paginate(sessions)
        total_pages = [(sessions.length.to_f / PER_PAGE).ceil, 1].max
        page        = params[:page].to_i
        page        = 1 if page < 1
        page        = total_pages if page > total_pages
        offset      = (page - 1) * PER_PAGE
        { items: sessions.slice(offset, PER_PAGE) || [], page: page, total_pages: total_pages }
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
        query.empty? ? "/" : "/?#{query}"
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

      # Uncapped percentage for labels — shows >100% when a budget is exceeded
      # (bar widths still use the clamped `pct`).
      def pct_raw(used, max)
        max.to_i.positive? ? (used.to_f / max.to_i * 100).round : 0
      end

      # A small inline progress bar. `danger` paints it red (limit tripped).
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

      # In-transcript chip (§2.3): live context size as a mini-bar scaled to the
      # context window, plus the turn spend accumulating toward its cap.
      def ctx_chip(usage, running, context_window:, max_turn_tokens:, model: nil, provider: nil, cost_usd: nil)
        return "" unless usage

        input = usage["input_tokens"].to_i
        out   = usage["output_tokens"].to_i
        cache = usage["cache_read_input_tokens"].to_i

        parts = []
        # Turn spend first and bar-backed — it's what trips max_tokens, so it's
        # the signal worth watching fill as you scroll.
        if max_turn_tokens.to_i.positive?
          danger = running.to_i > max_turn_tokens.to_i ? " danger" : ""
          parts << %(<span class="ctx-turn#{danger}">turn #{fmt_tokens(running)}/#{fmt_tokens(max_turn_tokens)}</span>)
          parts << %(<span class="ctx-bar"><span class="ctx-bar-fill#{danger}" style="width: #{pct(running, max_turn_tokens)}%"></span></span>)
        end
        # Live context size second, with a smaller mini-bar.
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
      # `points` is the Session#usage_series; faint vertical lines mark turn
      # boundaries, a notch marks compactions. No JS, no chart library.
      def sparkline(points, max:, width: 640, height: 48)
        return "" if points.length < 2

        max = 1 if max.to_i < 1
        step = width.to_f / (points.length - 1)

        coords = points.each_with_index.map do |p, i|
          x = (i * step).round(1)
          y = (height - (p.input.to_f / max * (height - 4)) - 2).round(1)
          "#{x},#{y}"
        end.join(" ")

        # Faint vertical rule at each turn's first iteration (after turn 1).
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
      erb :session
    end
  end
end
