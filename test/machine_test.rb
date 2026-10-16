# frozen_string_literal: true

require_relative "test_helper"

# What a machine is, as the stamp that expires the facts it establishes.
#
# The stamp exists because an `unexaminable` record is a fact about a release *and* about the
# machine that tried it, and a fact that names only half of that outlives the reason for it.
# Two halves here, and one of them was wrong in a way the live ledger showed: 862 of the Ruby
# ledger's 1,844 pairs were settled unbuildable while carrying `cpython 3.12`, and every one of
# them was `prism`, `bigdecimal`, `racc`, `json` or `nokogiri` failing for the want of a
# compiler rather than anything about the gem.
#
# The toolchain is read from `PATH`, so these tests put a `PATH` in place — along with the
# interpreter, which is a subprocess here rather than `sys.executable` and therefore has to be
# stubbed at the same seam.
class MachineTest < MinerTest
  def setup
    super
    @bin = dir("bin")
    (%w[cc gcc make ruby] + [AgentsFyiMiner::Machine.interpreter]).each do |name|
      file = @bin.join(name)
      # The interpreter is a subprocess here rather than `sys.executable`, so the shim answers
      # the version question and nothing else.
      file.write("#!/bin/sh\nprintf '3.12\\n'\n")
      file.chmod(0o755)
    end
  end

  def test_a_machine_with_a_compiler_and_make_is_stamped_cc
    ENV["PATH"] = @bin.to_s

    assert_equal AgentsFyiMiner::Machine::CC, AgentsFyiMiner::Machine.toolchain
  end

  def test_make_without_a_compiler_is_not_a_toolchain
    # `gem install` needs both, and its failure for the second is
    # `make failedNo such file or directory - make` — so a compiler alone must not be
    # reported as this machine being able to build an extension.
    @bin.join("cc").delete
    @bin.join("gcc").delete
    ENV["PATH"] = @bin.to_s

    assert_equal AgentsFyiMiner::Machine::NO_CC, AgentsFyiMiner::Machine.toolchain
  end

  def test_neither_tool_is_required_to_be_a_compiler
    # `cc` is the standard name and `gcc` is the common one; a machine with one of them and
    # `make` builds extensions.
    @bin.join("cc").delete
    ENV["PATH"] = @bin.to_s

    assert_equal AgentsFyiMiner::Machine::CC, AgentsFyiMiner::Machine.toolchain
  end

  def test_the_stamp_names_both_halves
    # The whole point: a record that says `cpython 3.12` cannot be expired by adding a
    # compiler, and one that says `no-cc` can.
    ENV["PATH"] = dir("empty").to_s
    without = AgentsFyiMiner::Machine.python
    ENV["PATH"] = @bin.to_s
    with_tools = AgentsFyiMiner::Machine.python

    assert without.end_with?(AgentsFyiMiner::Machine::NO_CC), without
    assert with_tools.end_with?(AgentsFyiMiner::Machine::CC), with_tools
    refute_equal without, with_tools, "adding a compiler has to change what the machine is"
    assert with_tools.start_with?("cpython"), "the stamp names the interpreter it measured"
  end
end
