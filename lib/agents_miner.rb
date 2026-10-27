# frozen_string_literal: true

# The reproduction miner, in Ruby — the second client of this service, and the one that grows
# the corpus.
#
# What is *not* a file-for-file change is the language's shape, and three differences are
# worth stating where a reader meets them first:
#
#
# Every file requires what it uses (`require_relative`), so this loader is a plain glob: a
# new module is a new file and nothing else, and no file's position in an alphabetical list
# decides whether it loads.
require "pathname"

Dir[File.join(__dir__, "agents_miner", "*.rb")].sort.each { |file| require file }

module AgentsMiner
  VERSION = "2.0.0"
end
