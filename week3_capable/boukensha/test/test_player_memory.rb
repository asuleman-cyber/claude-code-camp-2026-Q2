require_relative "helper"
require "tmpdir"
require "json"
require "boukensha/player_memory"

# Phase J — cross-session character memory.
class TestPlayerMemory < Minitest::Test
  include McpTestHelper

  def with_memory(name: "Gandalf")
    Dir.mktmpdir do |dir|
      yield Boukensha::PlayerMemory.new(dir: dir, name: name), dir
    end
  end

  # ---- names become filenames ------------------------------------------

  def test_sanitize_keeps_ordinary_names
    assert_equal "Gandalf",   Boukensha::PlayerMemory.sanitize("Gandalf")
    assert_equal "grey-wiz_1", Boukensha::PlayerMemory.sanitize("grey-wiz_1")
  end

  # The name comes from settings.yaml and becomes a path, so it is
  # whitelisted rather than escaped.
  def test_sanitize_strips_path_traversal
    refute_includes Boukensha::PlayerMemory.sanitize("../../etc/passwd").to_s, "/"
    refute_includes Boukensha::PlayerMemory.sanitize("..\\windows").to_s, "\\"
    refute_includes Boukensha::PlayerMemory.sanitize("a/b").to_s, "/"
  end

  def test_sanitize_rejects_empty_names
    assert_nil Boukensha::PlayerMemory.sanitize("")
    assert_nil Boukensha::PlayerMemory.sanitize("   ")
    assert_nil Boukensha::PlayerMemory.sanitize(nil)
    assert_nil Boukensha::PlayerMemory.sanitize("///")
  end

  # ---- build ------------------------------------------------------------

  def test_build_returns_nil_when_disabled
    config_from("") do |cfg|
      assert_nil Boukensha::PlayerMemory.build(config: cfg, name: "Gandalf", enabled: false)
    end
  end

  def test_build_returns_nil_without_a_usable_name
    config_from("") do |cfg|
      assert_nil Boukensha::PlayerMemory.build(config: cfg, name: nil, enabled: true)
      assert_nil Boukensha::PlayerMemory.build(config: cfg, name: "  ", enabled: true)
    end
  end

  def test_build_creates_a_memory_under_the_config_dir
    config_from("") do |cfg|
      mem = Boukensha::PlayerMemory.build(config: cfg, name: "Gandalf", enabled: true)
      refute_nil mem
      assert_equal "Gandalf", mem.name
      assert_includes mem.dir, cfg.dir
    end
  end

  # ---- raw records ------------------------------------------------------

  def test_records_append_and_never_rewrite
    with_memory do |mem|
      mem.record(kind: "session", reason: "exit")
      mem.record(kind: "session", reason: "eof")

      records = mem.recent_records
      assert_equal 2, records.size
      assert_equal %w[exit eof], records.map { |r| r["reason"] }
      assert_equal "Gandalf", records.first["name"]
      assert records.first["at"], "records are timestamped"
    end
  end

  def test_recent_records_returns_the_tail_oldest_first
    with_memory do |mem|
      10.times { |i| mem.record(kind: "n", i: i) }

      tail = mem.recent_records(limit: 3)
      assert_equal [7, 8, 9], tail.map { |r| r["i"] }
    end
  end

  def test_recent_records_is_empty_before_anything_is_written
    with_memory { |mem| assert_empty mem.recent_records }
  end

  # A process killed mid-write leaves a torn final line; that is not a
  # reason to lose the whole memory.
  def test_a_torn_line_is_skipped_not_fatal
    with_memory do |mem|
      mem.record(kind: "good")
      File.open(mem.jsonl_path, "a") { |io| io.print('{"kind":"tor') }

      records = mem.recent_records
      assert_equal 1, records.size
      assert_equal "good", records.first["kind"]
    end
  end

  # ---- the digest -------------------------------------------------------

  def test_digest_is_nil_until_written
    with_memory { |mem| assert_nil mem.digest }
  end

  def test_write_and_read_a_digest
    with_memory do |mem|
      assert mem.write_digest("## Discoveries\nThe temple is north.")
      assert_includes mem.digest, "The temple is north."
    end
  end

  # Rewritten wholesale, not appended — a memory that only grows stops being
  # affordable to read.
  def test_writing_a_digest_replaces_the_previous_one
    with_memory do |mem|
      mem.write_digest("first memory")
      mem.write_digest("second memory")

      assert_includes mem.digest, "second memory"
      refute_includes mem.digest, "first memory"
    end
  end

  def test_a_blank_digest_is_refused
    with_memory do |mem|
      mem.write_digest("real")
      refute mem.write_digest("   ")
      assert_includes mem.digest, "real", "a blank rewrite must not wipe real memory"
    end
  end

  # A Chronicler that ignores its length budget must not be able to inflate
  # every future planning call.
  def test_an_overlong_digest_is_truncated
    with_memory do |mem|
      mem.write_digest((["a line of remembered text"] * 500).join("\n"))

      assert_operator mem.digest.length, :<=, Boukensha::PlayerMemory::MAX_DIGEST_CHARS + 50
      assert_includes mem.digest, "truncated"
    end
  end

  def test_writing_a_digest_leaves_a_raw_record
    with_memory do |mem|
      mem.write_digest("something")
      assert_includes mem.recent_records.map { |r| r["kind"] }, "digest_written"
    end
  end

  def test_empty_reports_whether_anything_is_remembered
    with_memory do |mem|
      assert mem.empty?
      mem.write_digest("something")
      refute mem.empty?
    end
  end

  # ---- file handling ----------------------------------------------------

  # Open-append-close, never a held handle: a handle held open by one
  # process blocks another from deleting the file on Windows, which broke
  # Dir.mktmpdir cleanup in Phase B/D. If this regresses, mktmpdir raises.
  def test_writes_do_not_hold_the_file_open
    dir = Dir.mktmpdir
    mem = Boukensha::PlayerMemory.new(dir: dir, name: "Gandalf")
    mem.record(kind: "one")
    mem.write_digest("two")

    FileUtils.remove_entry(dir) # would fail on Windows with a handle held
    refute Dir.exist?(dir)
  end

  # Memory failing must never take down a turn.
  def test_a_failing_write_returns_false_instead_of_raising
    mem = Boukensha::PlayerMemory.new(dir: Dir.mktmpdir, name: "Gandalf")
    def mem.jsonl_path = "/nonexistent-dir-#{Time.now.to_i}/x.jsonl"

    refute mem.record(kind: "boom")
  end

  def test_an_unreadable_digest_reads_as_nil
    with_memory do |mem|
      def mem.digest_path = "/nonexistent-dir/x.md"
      assert_nil mem.digest
    end
  end
end
