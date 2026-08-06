require "digest"

module Boukensha
  module Mud
    # Room identity, computed from what a `look`/`inspect` actually returned
    # — never a server-assigned id, because the MUD doesn't give the agent
    # one. Two fingerprints, because the inputs cost different amounts (per
    # docs/plans/week_2/basic_memory.md §4.1):
    #
    #   weak   — name + description + sorted exit directions. Free: every
    #            look (and every move result) carries this.
    #   strong — weak + sorted "direction->destination name" pairs. Costs
    #            the `exits` half of the `inspect` composite (Phase A), so
    #            it's only available once a room has actually been surveyed.
    #
    # Deliberately NOT used as a database UNIQUE constraint (see Store) —
    # two genuinely different rooms with identical prose and exit *shape*
    # (no destination names known yet) are possible, and treating a
    # fingerprint collision as certain identity would silently teach the
    # agent a wrong map. This module only computes the hash; Store decides
    # what to do with a collision.
    module Fingerprint
      module_function

      def weak(name:, description:, exit_directions:)
        digest(name, normalize(description), exit_directions.map(&:to_s).sort.join(","))
      end

      # destinations: { "north" => "By The Temple Altar", ... } — nil
      # destinations (server couldn't identify one, e.g. "Too dark to
      # tell.") are included as literal text so a genuinely unknown
      # destination doesn't silently match a different genuinely unknown one.
      def strong(weak_fingerprint:, exit_targets:)
        pairs = exit_targets.map { |dir, dest| "#{dir}=#{normalize(dest)}" }.sort.join(",")
        digest(weak_fingerprint, pairs)
      end

      def normalize(text)
        text.to_s.downcase.gsub(/\s+/, " ").strip
      end

      def digest(*parts)
        Digest::SHA256.hexdigest(parts.join("|"))
      end
    end
  end
end
