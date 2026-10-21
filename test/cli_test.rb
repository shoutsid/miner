# frozen_string_literal: true

require_relative "test_helper"

# The command line, which is how this client is reached at all.
#
# The five modes are the surface an operator and the container's `entrypoint.sh` both use, and
# the failure this file exists to prevent is a *parse* failure rather than a behaviour one: a
# flag renamed here and read as an attribute there is a miner that starts and silently mines
# nothing, or a verifier that runs the other method under the other method's account.
#
# Nothing here reaches the network or installs anything: `main` is exercised only on the paths that
# return before any work starts (help, and a usage error), and every other test drives the parser or
# the default resolution directly.
class CliTest < MinerTest
  C = AgentsFyiMiner::Cli

  def parse(argv) = C.build_parser.parse(argv)

  def test_every_mode_parses_to_itself
    C::COMMANDS.each do |command|
      args = parse([command])

      assert_equal command, args.command
    end
  end

  def test_a_command_that_is_not_one_of_the_five_is_refused_by_name
    error = assert_raises(C::UsageError) { parse(%w[mine-some]) }

    assert_includes error.message, "invalid choice"
    assert_includes error.message, "mine-some"
  end

  def test_no_command_at_all_is_a_usage_error
    error = assert_raises(C::UsageError) { parse([]) }

    assert_includes error.message, "required: command"
  end

  def test_a_second_positional_argument_is_refused_rather_than_ignored
    error = assert_raises(C::UsageError) { parse(%w[mine publish]) }

    assert_includes error.message, "unrecognized arguments"
  end

  def test_the_defaults_are_the_ones_the_python_client_declared
    args = parse(["mine"])

    assert_equal C::DEFAULT_BASE, args.base_url
    assert_equal 1, args.span
    assert_equal 0, args.limit
    assert_equal C::QUEUE_PAGES, args.queue_pages
    assert_equal 1, args.report_budget
    assert_equal "INFO", args.log_level
    assert_equal AgentsFyiMiner::Verifying::AS_REPORTED, args.role
    assert_equal AgentsFyiMiner::Service::DEFAULT_WORKERS, args.workers
    assert_equal AgentsFyiMiner::Service::WRITES_PER_HOUR, args.writes_per_hour
    assert_equal AgentsFyiMiner::Service::DOWNLOAD_MBPS, args.download_mbps
    refute args.json
    refute args.dry_run
    refute args.no_sleep
    assert_empty args.package
    assert_nil args.home, "the per-mode home is resolved in main, not by the parser"
    assert_nil args.budget, "likewise the per-mode budget"
  end

  def test_the_index_list_comes_from_the_environment_when_it_is_not_given
    ENV["MINER_ECOSYSTEMS"] = "ruby"

    assert_equal "ruby", parse(["serve"]).ecosystems
  ensure
    ENV.delete("MINER_ECOSYSTEMS")
  end

  def test_the_from_and_to_flags_are_the_two_versions_of_one_pair
    args = parse(%w[mine --from 1.0 --to 2.0 --package httpx])

    assert_equal "1.0", args.from_version
    assert_equal "2.0", args.to_version
    assert_equal ["httpx"], args.package
  end

  def test_a_package_can_be_named_more_than_once
    assert_equal %w[httpx rich], parse(%w[mine --package httpx --package rich]).package
  end

  def test_a_path_flag_is_a_path_rather_than_a_string
    args = parse(%w[mine --home /tmp/miner-home --state /tmp/key.json --heartbeat /tmp/beats])

    assert_kind_of Pathname, args.home
    assert_equal "/tmp/miner-home", args.home.to_s
    assert_kind_of Pathname, args.state
    assert_kind_of Pathname, args.heartbeat
  end

  def test_an_unknown_flag_is_a_usage_error_rather_than_an_ignored_word
    assert_raises(C::UsageError) { parse(%w[mine --nope]) }
  end

  def test_a_role_that_is_not_one_of_the_two_is_refused_when_verify_is_the_command
    # The consequence is a vote, not a typo: the two roles are two different executions filed under
    # two different accounts, so a defaulted misspelling would cast the other one.
    assert_raises(C::UsageError) { parse(%w[verify --role as_reported]) }
    refute_nil parse(%w[verify --role searched])
  end

  def test_a_bad_role_does_not_stop_a_command_that_has_no_use_for_one
    assert_equal "mine", parse(%w[mine --role nonsense]).command
  end

  # The watchlist depth describes the *deployment*, so it is read from the environment.
  def test_the_top_default_comes_from_miner_top
    ENV.delete("MINER_TOP")
    assert_equal AgentsFyiMiner::Watchlist::DEFAULT_TOP, C.env_top

    ENV["MINER_TOP"] = "500"
    assert_equal 500, C.env_top
  end

  def test_a_top_that_is_not_a_positive_integer_is_ignored_rather_than_fatal
    # A miner that refused to start over a typo in a tuning knob would be trading all of its work
    # for nothing.
    %w[zero 0 -5 3.5].each do |value|
      ENV["MINER_TOP"] = value

      assert_equal AgentsFyiMiner::Watchlist::DEFAULT_TOP, C.env_top, value
    end
  end

  # One parser cannot say two defaults for one flag, so they are resolved per mode.
  def test_the_default_home_and_budget_differ_between_the_miner_and_the_verifier
    miner = C.resolve_defaults(parse(["serve"]))
    verifier = C.resolve_defaults(parse(["verify"]))

    assert_equal C::DEFAULT_HOME, miner.home
    assert_equal C::DEFAULT_VERIFIER_HOME, verifier.home
    assert_equal AgentsFyiMiner::Planner::DEFAULT_BUDGET, miner.budget
    assert_equal C::VERIFY_BUDGET, verifier.budget
    assert_equal C.env_top, miner.top
  end

  def test_an_explicit_home_and_budget_are_not_overwritten_by_the_per_mode_defaults
    args = C.resolve_defaults(parse(%w[verify --home /tmp/elsewhere --budget 2]))

    assert_equal "/tmp/elsewhere", args.home.to_s
    assert_equal 2, args.budget
  end

  def test_help_prints_usage_and_is_not_a_run
    status = nil
    out, = capture_io { status = C.main(["-h"]) }

    assert_equal 0, status
    assert_includes out, "agents-fyi-miner"
    assert_includes out, "--package"
  end

  def test_version_prints_the_client_version_and_is_not_a_run
    status = nil
    out, err = capture_io { status = C.main(["--version"]) }

    assert_equal 0, status
    assert_equal "#{AgentsFyiMiner::VERSION}\n", out
    assert_empty err
  end

  def test_mine_prints_without_registering_or_filing
    args = parse(["mine", "--package", "httpx", "--from", "1.0", "--to", "2.0",
                  "--home", @home.to_s])
    C.resolve_defaults(args)
    pair = AgentsFyiMiner::Pair.of(package: "httpx", from_version: "1.0", to_version: "2.0")

    original_resolve = C.method(:resolve_pairs)
    original_mine = C.method(:mine_pair)
    C.define_singleton_method(:resolve_pairs) { |*_args, **_kwargs| [pair] }
    C.define_singleton_method(:mine_pair) { |*_args, **_kwargs| [] }

    status = nil
    _out, err = capture_io { status = C.run_once(args) }

    assert_equal 0, status
    assert_includes err, "nothing was filed"
    refute File.exist?(@home + "operator.json"), "mine registered an operator and could have filed"
  ensure
    C.define_singleton_method(:resolve_pairs, original_resolve) if original_resolve
    C.define_singleton_method(:mine_pair, original_mine) if original_mine
  end

  def test_main_answers_a_usage_error_with_argparses_status
    status = nil
    _out, err = capture_io { status = C.main(%w[mine --nope]) }

    assert_equal 2, status, "1 means 'the run happened and found nothing', which a supervisor retries"
    assert_includes err, "error:"
  end

  def test_the_workers_and_write_budget_default_to_the_services_own_numbers
    # Read from the constants rather than written out again, because two spellings of one default is
    # how a container and its client come to disagree about how much work they are doing — the
    # `limit_max` trap in `Watchlist`, one field over.
    args = parse(["serve"])

    assert_equal AgentsFyiMiner::Service::DEFAULT_WORKERS, args.workers
    assert_equal AgentsFyiMiner::Service::WRITES_PER_HOUR, args.writes_per_hour
    assert_equal AgentsFyiMiner::Service::DOWNLOAD_MBPS, args.download_mbps
  end

  def test_a_verifier_registers_under_the_account_its_role_names
    # The service counts *distinct* operators, so the two methods are two accounts — and the two
    # names are the ones the deployment's own environment expects to see.
    as_reported = C::VERIFIER_IDENTITIES.fetch(AgentsFyiMiner::Verifying::AS_REPORTED)
    searched = C::VERIFIER_IDENTITIES.fetch(AgentsFyiMiner::Verifying::SEARCHED)

    assert_equal "claim-verifier@agents.shoutsid.fyi", as_reported[1]
    assert_equal "surface-verifier@agents.shoutsid.fyi", searched[1]
    refute_equal as_reported[1], searched[1]
  end
end
