# frozen_string_literal: true

require_relative "stub_helper"
require_relative "test_helper"

# The boot cell: a release that requires cleanly and still refuses to come up.
#
# Nothing here installs a gem or starts an interpreter. The seam is the command runner, and what is
# asserted is the judgement each outcome makes — including the one that matters most, that a host
# which could not be built is `unexaminable` rather than a `finding` about the release.
class BootTest < MinerTest
  include StubHelper

  B = AgentsMiner::Boot

  # `bundle install` then `bundle exec ruby boot_host.rb` are two calls; the stub answers them in
  # order, and the second is the boot the test is about.
  def boot(install_status: 0, status: 0, stdout: "", stderr: "")
    calls = 0
    with_stub(AgentsMiner::Envs, :run_captured, lambda do |*_args, **_kwargs|
      calls += 1
      if calls == 1
        AgentsMiner::Envs::Result.new(status: install_status, stdout: "", stderr: "")
      else
        AgentsMiner::Envs::Result.new(status: status, stdout: stdout, stderr: stderr)
      end
    end) { yield }
  end

  def test_a_release_that_boots_is_clean
    cell = boot(status: 0, stdout: "booted") { B.cell("rack-test", "2.1.0", home: @home) }

    assert_equal "clean", cell.fetch(:outcome)
    assert_includes cell.fetch(:note), "exit 0"
  end

  def test_a_release_that_raises_on_boot_is_a_finding
    cell = boot(status: 1, stderr: "boot_host.rb:3:in `require': cannot load such file -- nope") do
      B.cell("broken-gem", "1.0.0", home: @home)
    end

    assert_equal "findings", cell.fetch(:outcome)
    assert_includes cell.fetch(:note), "failed to boot"
    assert_includes cell.fetch(:note), "cannot load such file"
  end

  # **A host that could not be built established nothing about the release.** An install that failed
  # is `unexaminable`, not a finding: the release may be perfectly bootable on a machine with the
  # index.
  def test_an_install_that_failed_is_unexaminable
    cell = boot(install_status: 6, stderr: "Could not find compatible versions") do
      B.cell("actionpack", "7.1.6", home: @home)
    end

    assert_equal "unexaminable", cell.fetch(:outcome)
    assert_includes cell.fetch(:note), "bundle install"
  end

  # A deprecation at boot is a documented, observed signal and is named in the note rather than
  # left in the output.
  def test_a_deprecation_at_boot_is_named_in_the_note
    cell = boot(status: 0, stderr: "warning: `foo` is deprecated; use `bar`") do
      B.cell("rack-test", "2.1.0", home: @home)
    end

    assert_equal "clean", cell.fetch(:outcome)
    assert_includes cell.fetch(:note), "Warnings"
    assert_includes cell.fetch(:note), "deprecated"
  end

  # The framework pin is added for a component gem and only for one, and the host always declares
  # Rack because the host is a Rack app.
  def test_the_host_gemfile_pins_the_framework_and_declares_rack
    component = B.gemfile_for("actionpack", "7.1.6")
    assert_includes component, "gem \"rails\", \"7.1.6\""
    assert_includes component, "gem \"rack\""

    refute_includes B.gemfile_for("nokogiri", "1.16.0"), "gem \"rails\""
  end
end
