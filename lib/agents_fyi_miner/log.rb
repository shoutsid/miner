# frozen_string_literal: true

module AgentsFyiMiner
  # The log, in the shape the deployment's operators already read.
  #
  # A port that logged differently would keep working and stop being greppable, which is the
  # kind of change a rewrite should not make silently.
  #
  # Level is a *process* setting rather than a per-caller one, because it is set once from
  # `--log-level` before any work starts, and every module asks `Log` for a logger by name the
  # way `logging.getLogger` was asked. A name is kept as given so a line still says which
  # module wrote it.
  module Log
    LEVELS = { "DEBUG" => 0, "INFO" => 1, "WARNING" => 2, "ERROR" => 3 }.freeze

    # INFO, and that is a decision rather than a default: at DEBUG every probe's output is
    # printed, which is useful against one pair by hand and unreadable in a container that
    # examines thousands.
    def self.level = @level || "INFO"

    def self.level=(name)
      @level = LEVELS.key?(name.to_s.upcase) ? name.to_s.upcase : "INFO"
    end

    def self.debug? = LEVELS.fetch(level) <= LEVELS.fetch("DEBUG")

    def self.logger(name) = Logger.new(name)

    # One name's writer.
    class Logger
      def initialize(name) = @name = name

      def debug(message, *args) = write("DEBUG", message, args)
      def info(message, *args) = write("INFO", message, args)
      def warning(message, *args) = write("WARNING", message, args)
      def error(message, *args) = write("ERROR", message, args)

      def enabled?(level) = Log::LEVELS.fetch(level) >= Log::LEVELS.fetch(Log.level)

      private

      def write(level, message, args)
        return unless enabled?(level)

        text = args.empty? ? message.to_s : format(message.to_s, *args)
        $stderr.puts("#{stamp} #{level} #{@name} #{text}")
      end

      def stamp
        now = Time.now
        now.strftime("%Y-%m-%d %H:%M:%S,") + format("%03d", (now.usec / 1000))
      end
    end
  end
end
