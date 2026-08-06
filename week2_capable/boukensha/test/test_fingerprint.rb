require_relative "helper"
require "boukensha/mud/fingerprint"

class TestFingerprint < Minitest::Test
  F = Boukensha::Mud::Fingerprint

  def test_weak_is_deterministic
    a = F.weak(name: "Market Square", description: "busy", exit_directions: %w[north south])
    b = F.weak(name: "Market Square", description: "busy", exit_directions: %w[north south])
    assert_equal a, b
  end

  def test_weak_ignores_exit_direction_order
    a = F.weak(name: "Market Square", description: "busy", exit_directions: %w[north south])
    b = F.weak(name: "Market Square", description: "busy", exit_directions: %w[south north])
    assert_equal a, b
  end

  def test_weak_differs_on_description
    a = F.weak(name: "Market Square", description: "busy", exit_directions: %w[north])
    b = F.weak(name: "Market Square", description: "quiet", exit_directions: %w[north])
    refute_equal a, b
  end

  def test_weak_is_case_and_whitespace_insensitive_on_description
    a = F.weak(name: "Market Square", description: "A  Busy   square", exit_directions: %w[north])
    b = F.weak(name: "Market Square", description: "a busy square", exit_directions: %w[north])
    assert_equal a, b
  end

  def test_strong_differs_when_destinations_differ
    weak = F.weak(name: "Dark Alley", description: "d", exit_directions: %w[north south])
    a = F.strong(weak_fingerprint: weak, exit_targets: { "north" => "Market Square", "south" => "The Slums" })
    b = F.strong(weak_fingerprint: weak, exit_targets: { "north" => "Elsewhere", "south" => "The Slums" })
    refute_equal a, b
  end

  def test_strong_ignores_pair_order
    weak = F.weak(name: "Dark Alley", description: "d", exit_directions: %w[north south])
    a = F.strong(weak_fingerprint: weak, exit_targets: { "north" => "X", "south" => "Y" })
    b = F.strong(weak_fingerprint: weak, exit_targets: { "south" => "Y", "north" => "X" })
    assert_equal a, b
  end
end
