# frozen_string_literal: true

# Replacing module methods for the length of a block, the way `monkeypatch.setattr` did — with the
# originals put back afterwards, because these are process-global and a test that left one behind
# would decide the next test's answer.
#
# `instance_exec` rather than `define_singleton_method(name, &body)`, and that is the whole reason
# this is a helper rather than two lines in each file: a block handed to `define_method` runs with
# `self` bound to the *receiver*, so a stub that called `assert` or one of its test's own helpers
# would be calling it on the stubbed module and fail with `undefined method 'assert' for module …`.
# Running the block against the test keeps the helpers reachable while the arguments still arrive as
# the call's.
#
# `ruby_envs_test.rb` carries its own copy of `with_stub`, written before this file existed; it
# should be folded in here, which is the coordinator's call rather than a second edit from the slice
# that added this one.
module StubHelper
  # One method, for the length of a block. `body` is a lambda or a block, and either may be handed
  # in — `with_stub(Mod, :m) { |a| … }` and `with_stub(Mod, :m, lambda) { }` both read.
  def with_stub(mod, name, body = nil, &block)
    with_stubs(mod, { name => (body || block) }) { yield }
  end

  # Several at once, because the four probe functions are only meaningful together: a differential
  # stubbed in one direction and not the other answers from two different releases.
  def with_stubs(mod, bodies)
    originals = {}
    test = self
    bodies.each do |name, body|
      originals[name] = mod.singleton_class.instance_method(name)
      mod.define_singleton_method(name) do |*args, **kwargs, &blk|
        test.instance_exec(*args, **kwargs, &body)
      end
    end
    yield
  ensure
    originals.each do |name, original|
      mod.singleton_class.send(:define_method, name, original)
    end
  end
end
