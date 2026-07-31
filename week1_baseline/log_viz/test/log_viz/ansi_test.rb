require "minitest/autorun"
require "log_viz/ansi"

module LogViz
  class AnsiTest < Minitest::Test
    def test_plain_text_passes_through_escaped
      assert_equal "hello", Ansi.to_html("hello")
    end

    def test_escapes_html_special_characters
      assert_equal %(&lt;a&gt; &amp; "b"), Ansi.to_html(%(<a> & "b"))
    end

    def test_escape_html_covers_amp_lt_gt
      assert_equal "&amp;&lt;&gt;", Ansi.escape_html("&<>")
    end

    def test_single_sgr_code_wraps_in_span
      assert_equal '<span class="ansi-fg-red">hi</span>', Ansi.to_html("\e[31mhi")
    end

    def test_bold_and_color_combine_into_one_span
      html = Ansi.to_html("\e[1;32mhi\e[0m")
      assert_equal '<span class="ansi-bold ansi-fg-green">hi</span>', html
    end

    def test_reset_code_clears_active_classes
      html = Ansi.to_html("\e[31mred\e[0mplain")
      assert_equal '<span class="ansi-fg-red">red</span>plain', html
    end

    def test_default_fg_39_clears_only_foreground
      html = Ansi.to_html("\e[31;41mx\e[39my")
      assert_equal '<span class="ansi-fg-red ansi-bg-red">x</span><span class="ansi-bg-red">y</span>', html
    end

    def test_default_bg_49_clears_only_background
      html = Ansi.to_html("\e[31;41mx\e[49my")
      assert_equal '<span class="ansi-fg-red ansi-bg-red">x</span><span class="ansi-fg-red">y</span>', html
    end

    def test_unknown_code_is_ignored
      html = Ansi.to_html("\e[99mhi")
      assert_equal "hi", html
    end

    def test_crlf_is_normalized_to_lf
      assert_equal "a\nb", Ansi.to_html("a\r\nb")
    end

    def test_empty_string
      assert_equal "", Ansi.to_html("")
    end

    def test_nil_input
      assert_equal "", Ansi.to_html(nil)
    end
  end
end
