require_relative "../primitives"

module MudManager
  module Mcp
    # The canonical, language-neutral table of gameplay tools. Every tool
    # schema (MCP tools/list, primitives.json) is generated from this one
    # table, and its dispatch lambdas are the only callers of
    # MudManager::Primitives — Ruby is the source of truth (see
    # docs/plans/mud_manager/generic_interfacing.md open-Q #4).
    module ToolSpec
      Param = Struct.new(:type, :description, :enum, :required, keyword_init: true)
      Tool  = Struct.new(:name, :description, :params, :dispatch, keyword_init: true)

      P = MudManager::Primitives

      module_function

      # Treat blank/absent as "not supplied". Boukensha (and any other host)
      # advertises every param so the model can supply optional ones too;
      # this is where a blank string becomes "the model omitted it".
      def present(value)
        v = value.to_s
        v.strip.empty? ? nil : value
      end

      def int(value)
        v = present(value)
        v && Integer(v)
      end

      def string_param(desc, required: false)
        Param.new(type: "string", description: desc, required: required)
      end

      def enum_param(desc, values, required: false)
        Param.new(type: "string", description: desc, enum: values, required: required)
      end

      def int_param(desc, required: false)
        Param.new(type: "integer", description: desc, required: required)
      end

      TOOLS = [
        Tool.new(
          name: "look", description: "Look around the room, or at something specific.",
          params: {
            target:      string_param("What to look at (room exit, object, person). Omit to look at the room."),
            preposition: enum_param("Where to look, relative to target.", P::LOOK_PREPS)
          },
          dispatch: ->(a) { P.look(mode: "look", target: present(a["target"]), preposition: present(a["preposition"])) }
        ),
        Tool.new(
          name: "examine", description: "Examine an object or person closely.",
          params: { target: string_param("What to examine.", required: true) },
          dispatch: ->(a) { P.examine(a["target"]) }
        ),
        Tool.new(
          name: "check", description: "Check your (or someone else's) condition.",
          params: { target: string_param("Who to check. Omit to check yourself.") },
          dispatch: ->(a) { P.diagnose(present(a["target"])) }
        ),
        Tool.new(
          name: "move", description: "Move one step in a compass direction (or up/down).",
          params: { direction: enum_param("Direction to move.", P::DIRECTIONS, required: true) },
          dispatch: ->(a) { P.move(a["direction"]) }
        ),
        Tool.new(
          name: "flee", description: "Flee from combat in a random direction.",
          params: {}, dispatch: ->(_a) { P.flee }
        ),
        Tool.new(
          name: "set_position", description: "Change your posture (stand, sit, rest, sleep, wake).",
          params: { pos: enum_param("Target posture.", P::POSITIONS, required: true) },
          dispatch: ->(a) { P.set_position(a["pos"]) }
        ),
        Tool.new(
          name: "track", description: "Track a victim's trail.",
          params: { victim: string_param("Who to track.", required: true) },
          dispatch: ->(a) { P.track(a["victim"]) }
        ),
        Tool.new(
          name: "attack", description: "Attack a target with the given style.",
          params: {
            style:  enum_param("Attack style. Defaults to kill.", P::ATTACK_STYLES),
            target: string_param("Who to attack.", required: true)
          },
          dispatch: ->(a) { P.attack(present(a["style"]) || "kill", a["target"]) }
        ),
        Tool.new(
          name: "skill_strike", description: "Use a combat skill (backstab, bash, kick, rescue, assist) on a target.",
          params: {
            skill:  enum_param("Skill to use.", P::STRIKE_SKILLS, required: true),
            target: string_param("Who to use it on.", required: true)
          },
          dispatch: ->(a) { P.skill_strike(a["skill"], a["target"]) }
        ),
        Tool.new(
          name: "consider", description: "Size up a target before fighting it.",
          params: { target: string_param("Who to consider.", required: true) },
          dispatch: ->(a) { P.consider(a["target"]) }
        ),
        Tool.new(
          name: "say", description: "Say, emote, or reply something locally.",
          params: {
            mode: enum_param("How to say it. Defaults to say.", P::LOCAL_SAY),
            text: string_param("What to say.", required: true)
          },
          dispatch: ->(a) { P.say_local(present(a["mode"]) || "say", a["text"]) }
        ),
        Tool.new(
          name: "tell", description: "Send a private message to another player.",
          params: {
            target: string_param("Who to tell.", required: true),
            text:   string_param("What to tell them.", required: true)
          },
          dispatch: ->(a) { P.say_targeted("tell", a["target"], a["text"]) }
        ),
        Tool.new(
          name: "channel_say", description: "Speak on a global channel.",
          params: {
            channel: enum_param("Which channel.", P::CHANNELS, required: true),
            text:    string_param("What to say.", required: true)
          },
          dispatch: ->(a) { P.say_channel(a["channel"], a["text"]) }
        ),
        Tool.new(
          name: "get_item", description: "Pick up an item, optionally from a container.",
          params: {
            obj:       string_param("Item to get.", required: true),
            container: string_param("Container to get it from. Omit to get from the room."),
            count:     int_param("How many. Omit for one.")
          },
          dispatch: ->(a) { P.get(a["obj"], container: present(a["container"]), count: int(a["count"])) }
        ),
        Tool.new(
          name: "drop_item", description: "Drop, donate, or junk an item.",
          params: {
            mode:  enum_param("How to get rid of it. Defaults to drop.", P::DROP_MODES),
            obj:   string_param("Item to drop.", required: true),
            count: int_param("How many. Omit for one.")
          },
          dispatch: ->(a) { P.drop(present(a["mode"]) || "drop", a["obj"], count: int(a["count"])) }
        ),
        Tool.new(
          name: "put_item", description: "Put an item into a container.",
          params: {
            obj:       string_param("Item to put.", required: true),
            container: string_param("Container to put it in.", required: true),
            count:     int_param("How many. Omit for one.")
          },
          dispatch: ->(a) { P.put(a["obj"], a["container"], count: int(a["count"])) }
        ),
        Tool.new(
          name: "equip_item", description: "Wear, wield, hold, grab, or remove an item.",
          params: {
            op:       enum_param("Equip operation.", P::EQUIP_OPS, required: true),
            obj:      string_param("Item.", required: true),
            body_loc: string_param("Body location, for items that need one (e.g. a ring hand).")
          },
          dispatch: ->(a) { P.equip(a["op"], a["obj"], body_loc: present(a["body_loc"])) }
        ),
        Tool.new(
          name: "consume_item", description: "Eat, taste, drink, or sip something.",
          params: {
            mode: enum_param("Consumption mode.", P::CONSUME_MODES, required: true),
            obj:  string_param("Item to consume.", required: true)
          },
          dispatch: ->(a) { P.consume(a["mode"], a["obj"]) }
        ),
        Tool.new(
          name: "cast_spell", description: "Cast a spell, optionally at a target.",
          params: {
            spell:  string_param("Spell name.", required: true),
            target: string_param("Target of the spell. Omit for self/no target.")
          },
          dispatch: ->(a) { P.cast(a["spell"], target: present(a["target"])) }
        ),
        Tool.new(
          name: "use_magic_item", description: "Use, quaff, or recite a magic item.",
          params: {
            mode:        enum_param("How to use it.", P::SPELL_ITEM, required: true),
            item:        string_param("Item to use.", required: true),
            target_args: string_param("Extra target arguments, if the item needs one.")
          },
          dispatch: ->(a) { P.use_magic_item(a["mode"], a["item"], target_args: present(a["target_args"])) }
        ),
        Tool.new(
          name: "shop", description: "Interact with a shopkeeper: buy, sell, list, value, or offer.",
          params: {
            op:   enum_param("Shop operation.", P::SHOP_OPS, required: true),
            args: string_param("Arguments for the operation (e.g. an item name).")
          },
          dispatch: ->(a) { P.shop(a["op"], args: present(a["args"])) }
        ),
        Tool.new(
          name: "practice", description: "Practice a skill, or list practicable skills if none given.",
          params: { skill: string_param("Skill to practice. Omit to list skills.") },
          dispatch: ->(a) { P.practice(present(a["skill"])) }
        ),
        Tool.new(
          name: "save_character", description: "Save your character to disk.",
          params: {}, dispatch: ->(_a) { P.save_char }
        ),
        Tool.new(
          name: "send_raw",
          description: "Send a raw command line directly to the MUD, bypassing the typed primitives. Escape hatch.",
          params: { raw: string_param("The raw command line to send.", required: true) },
          dispatch: :raw
        ),
        Tool.new(
          name: "poll",
          description: "Return any buffered output that arrived since the last command, without sending anything.",
          params: {}, dispatch: :poll
        ),
        Tool.new(
          name: "mud_status",
          description: "Report whether the daemon currently has a live session with the MUD.",
          params: {}, dispatch: :status
        )
      ].freeze

      BY_NAME = TOOLS.each_with_object({}) { |t, h| h[t.name] = t }.freeze

      def find(name) = BY_NAME[name]

      def to_mcp_tools
        TOOLS.map do |t|
          {
            "name"        => t.name,
            "description" => t.description,
            "inputSchema" => {
              "type"       => "object",
              "properties" => t.params.each_with_object({}) do |(k, p), h|
                prop = { "type" => p.type, "description" => p.description.to_s }
                prop["enum"] = p.enum if p.enum
                h[k.to_s] = prop
              end,
              "required" => t.params.select { |_, p| p.required }.keys.map(&:to_s)
            }
          }
        end
      end
    end
  end
end
