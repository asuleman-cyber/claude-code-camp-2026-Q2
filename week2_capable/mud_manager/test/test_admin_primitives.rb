require_relative "helper"

# Admin primitives are never exposed as MCP tools (see the "Admin" section
# comment in primitives.rb) — they exist for operator scripts like
# week2_capable/bin/reset that log in as an immortal character directly.
# Covering their command-string shape here is the only test path they get.
class TestAdminPrimitives < Minitest::Test
  P = MudManager::Primitives

  def test_admin_goto_builds_the_goto_command
    cmd = P.admin_goto("3001")
    assert_equal "goto 3001", cmd.raw
    assert_equal :admin_goto, cmd.primitive
  end

  def test_admin_goto_accepts_a_room_name_too
    cmd = P.admin_goto("Temple Of Midgaard")
    assert_equal "goto Temple Of Midgaard", cmd.raw
  end

  def test_admin_goto_requires_a_target
    assert_raises(ArgumentError) { P.admin_goto("") }
    assert_raises(ArgumentError) { P.admin_goto(nil) }
  end

  def test_admin_transfer_builds_the_trans_command
    cmd = P.admin_transfer("dummy")
    assert_equal "trans dummy", cmd.raw
    assert_equal :admin_transfer, cmd.primitive
  end

  def test_admin_transfer_requires_a_target
    assert_raises(ArgumentError) { P.admin_transfer("") }
  end
end
