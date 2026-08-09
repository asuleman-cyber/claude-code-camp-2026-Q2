require_relative "helper"
require "socket"

# Regression coverage for Session#read_until_prompt's sentinel.
#
# The prompt used to be matched as the bare string "> ". That is not unique
# to the prompt: `equipment` opens every line with a slot label, so
# "<used as light> " contains "> " partway through the FIRST line of output.
# A real `equipment` reply came back truncated to
# "You are using:\r\n<used as light> " and parsed as zero items — silently,
# because a short valid-looking string raises nothing. Matching the vitals
# instead ("22H 100M 83V ... > ") fixes it.
class TestReadUntilPrompt < Minitest::Test
  PROMPT = "100H 100M 100V (news) (motd) > ".freeze

  # A one-shot server that writes `payload` to the first client and holds
  # the connection open, so read_until_prompt sees exactly these bytes.
  def with_server(payload)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      sock = server.accept
      sock.write(payload)
      sleep 5 # keep it open; the test finishes long before this
    ensure
      sock&.close rescue nil
    end
    thread.report_on_exception = false

    session = MudManager::Session.new(host: "127.0.0.1", port: server.addr[1], timeout: 3.0)
    session.open
    yield session
  ensure
    session&.close rescue nil
    thread&.kill
    server&.close rescue nil
  end

  def test_an_angle_bracket_in_the_payload_does_not_end_the_read
    equipment = "You are using:\r\n" \
                "<used as light>      a candle\r\n" \
                "<worn on finger>     a leather ring\r\n" \
                "<wielded>            a small sword\r\n" \
                "\r\n#{PROMPT}"

    with_server(equipment) do |session|
      out = session.read_until_prompt

      assert_includes out, "a candle"
      assert_includes out, "a small sword", "the read stopped at the first '> ' in a slot label"
      assert_equal 3, out.scan(/^</).length
    end
  end

  def test_the_read_stops_at_the_prompt_and_does_not_wait_for_the_timeout
    with_server("You do: look\r\n#{PROMPT}") do |session|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out = session.read_until_prompt
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_includes out, "You do: look"
      assert_operator elapsed, :<, 1.0, "should return on the prompt, not fall back to drain"
    end
  end

  # The fallback still has to work — this is what protects a session whose
  # prompt has been reconfigured away from the default vitals shape.
  def test_a_payload_with_no_recognisable_prompt_falls_back_to_draining
    with_server("Some output with no prompt at all\r\n") do |session|
      out = nil
      _, err = capture_io { out = session.read_until_prompt }

      assert_includes out, "Some output with no prompt at all"
      assert_match(/prompt not detected/, err)
    end
  end
end
