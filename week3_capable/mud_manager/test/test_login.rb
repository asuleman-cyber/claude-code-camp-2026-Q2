require_relative "helper"
require "mud_manager/fake_mud"

# Session#login had zero direct coverage before this file — every existing
# test drives it indirectly through Mcp::Dispatcher/SessionPool against the
# default FakeMud, which never exercised the "Did I get that right (Y/N)?"
# confirmation step some real servers insert before the password prompt.
# That gap is exactly how the missing-confirmation bug reached a live run
# undetected — see session.rb's login comment for how it actually surfaced
# (a live OTel trace showing three ~11.5s tool_call spans in a row).
class TestLogin < Minitest::Test
  def test_login_succeeds_on_first_connection
    fake = MudManager::FakeMud.new
    session = MudManager::Session.new(host: "127.0.0.1", port: fake.port)
    session.open
    session.login("Gandalf", "secret")

    session.close
    fake.stop
  end

  def test_login_succeeds_on_reconnect_to_an_already_known_name
    fake = MudManager::FakeMud.new
    first = MudManager::Session.new(host: "127.0.0.1", port: fake.port)
    first.open
    first.login("Gandalf", "secret")
    first.close

    second = MudManager::Session.new(host: "127.0.0.1", port: fake.port)
    second.open
    second.login("Gandalf", "secret") # exercises the "Reconnecting" branch

    second.close
    fake.stop
  end

  def test_login_raises_on_wrong_password
    fake = MudManager::FakeMud.new
    session = MudManager::Session.new(host: "127.0.0.1", port: fake.port)
    session.open

    assert_raises(MudManager::Session::LoginError) { session.login("Gandalf", "wrong") }

    session.close
    fake.stop
  end

  # This is the one that would have caught the real bug: without the fix,
  # login stalls on read_until(/Password/i) for the full session timeout
  # (never seeing "Password" because the server is waiting on a Y/N answer
  # it never gets), then raises MudManager::Session::Timeout.
  def test_login_answers_the_name_confirmation_prompt_when_present
    fake = MudManager::FakeMud.new(confirm_name: true)
    session = MudManager::Session.new(host: "127.0.0.1", port: fake.port, timeout: 3.0)
    session.open

    session.login("dummy", "secret")

    session.close
    fake.stop
  end
end
