# frozen_string_literal: true

# The suite, as one entry point: `ruby a.rb b.rb` runs `a.rb` with `b.rb` as an *argument*, so
# naming two files is how a second file's tests silently run zero assertions while the command
# looks right.
#
# `test_helper.rb` is not in this list and must not be: it defines no test, and its whole job
# is to be required by the files below.
Dir[File.join(__dir__, "*_test.rb")].sort.each { |file| require file }
