# frozen_string_literal: true

require_relative "test_helper"

# The work list: what has been done, and what must never be redone.
#
# Every test here passes `now:` rather than sleeping: `record_pair`, `due?` and `note_seen` all
# take the clock as an argument, which is the only reason a rule about a window can be asserted
# in a millisecond instead of waited out.
class LedgerTest < MinerTest
  Ledger = AgentsFyiMiner::Ledger

  def test_a_settled_pair_is_not_mined_again
    # The whole reason the ledger exists: a service restart is not a redo.
    store = Ledger.new
    store.record_pair("httpx", "0.27.2", "0.28.1", outcome: Ledger::DONE, findings: 4, filed: 4,
      now: 100.0)

    assert store.settled_pair?("httpx", "0.27.2", "0.28.1")
    refute store.due?("httpx", "0.27.2", "0.28.1", now: 1_000.0)
  end

  def test_a_pair_that_found_nothing_is_still_settled
    # Examined is examined. A release that changed nothing is not going to change its mind, and
    # re-installing both wheels to hear that again is the waste.
    store = Ledger.new
    store.record_pair("click", "8.0.0", "8.1.0", outcome: Ledger::EMPTY, now: 100.0)

    assert store.settled_pair?("click", "8.0.0", "8.1.0")
    assert_equal 0, store.yielded("click")
  end

  def test_a_failed_pair_is_retried_once_its_wait_is_over
    # A package that could not be installed because the index was briefly down is a package that
    # can be examined in an hour — which is the difference between a ledger that helps and one
    # that abandons work at the first network blip.
    store = Ledger.new
    store.record_pair("numpy", "2.0.0", "2.1.0", outcome: Ledger::FAILED, next_at: 200.0,
      now: 100.0)

    refute store.due?("numpy", "2.0.0", "2.1.0", now: 150.0)
    assert store.due?("numpy", "2.0.0", "2.1.0", now: 200.0)
  end

  def test_a_pair_that_kept_failing_is_left_alone_eventually
    # Otherwise a package that can never be examined — no wheel, no compiler — is attempted on
    # every pass for the life of the service.
    store = Ledger.new
    Ledger::MAX_PAIR_ATTEMPTS.times do
      store.record_pair("obscure", "1.0", "2.0", outcome: Ledger::FAILED, now: 100.0)
    end

    assert store.settled_pair?("obscure", "1.0", "2.0")
  end

  def test_a_release_that_cannot_be_built_here_is_settled_on_its_first_attempt
    # Three attempts are there to ride out a network blip. A release that is not on the index
    # will not appear on the second ask, and paying two more pip attempts per crossing to
    # establish that is how a cycle spends its whole pair budget on work that cannot happen.
    store = Ledger.new
    store.record_pair(
      "wrapt", "1.13.3", "1.14.0",
      outcome: Ledger::UNEXAMINABLE,
      note: "could not install wrapt==1.13.3: no matching distribution",
      release: "wrapt 1.13.3", now: 100.0
    )

    assert store.settled_pair?("wrapt", "1.13.3", "1.14.0")
    refute store.due?("wrapt", "1.13.3", "1.14.0", now: 1_000.0)
  end

  def test_an_unexaminable_pair_is_not_counted_as_a_pair_that_was_examined
    # `settled` is the planner's yield signal — "twelve releases examined, nothing found" — and a
    # package whose releases could not be built was examined zero times. Counting it as work done
    # is how a package that produced nothing reads as a package that was looked at, which is the
    # difference between deferring it and trying it again when the environment changes.
    store = Ledger.new
    ["1.14.0", "1.15.0"].each do |to_version|
      store.record_pair("wrapt", "1.13.3", to_version, outcome: Ledger::UNEXAMINABLE,
        release: "wrapt 1.13.3", now: 100.0)
    end

    assert_equal 0, store.settled("wrapt")
    assert_equal ["wrapt 1.13.3"], store.unexaminable("wrapt")
  end

  def test_an_unexaminable_pair_is_asked_again_when_the_interpreter_changes
    # The fact is about a release *and* about the machine that tried it: an sdist with no
    # wheel is refused because there is no wheel for this interpreter.
    store = Ledger.new
    store.machine = "cpython 3.12 cc"
    store.record_pair("wrapt", "1.13.3", "1.14.0", outcome: Ledger::UNEXAMINABLE,
      release: "wrapt 1.13.3", now: 100.0)

    assert_equal "cpython 3.12 cc", store.pair("wrapt", "1.13.3", "1.14.0").machine
    assert store.settled_pair?("wrapt", "1.13.3", "1.14.0")

    store.machine = "cpython 3.13 cc"
    refute store.settled_pair?("wrapt", "1.13.3", "1.14.0")
    assert store.due?("wrapt", "1.13.3", "1.14.0", now: 1_000.0)
    # And it is not reported to a reader as impossible here while it is being tried.
    assert_empty store.unexaminable("wrapt")
  end

  def test_the_picture_is_one_entry_per_release_with_the_stamp_that_established_it
    # The shape the service is told. Two crossings through one release are one fact — the record is
    # per pair, the fact is per release — and the machine travels with it, because the fact is about
    # the interpreter and the toolchain as well as about the release: a service told per pair would
    # rank a package by how many crossings happened to run through one dead release, and one told
    # without a stamp could never retire a fact an image bump settled.
    store = Ledger.new
    store.machine = "cpython 3.12 cc"
    store.record_pair("wrapt", "1.13.3", "1.14.0", outcome: Ledger::UNEXAMINABLE,
      note: "could not install wrapt==1.13.3: no matching distribution\nsecond line",
      release: "wrapt 1.13.3", now: 100.0)
    store.record_pair("wrapt", "1.13.3", "1.15.0", outcome: Ledger::UNEXAMINABLE,
      note: "a second attempt's own words", release: "wrapt 1.13.3", now: 101.0)
    store.record_pair("click", "8.0.0", "8.1.0", outcome: Ledger::DONE, now: 102.0)

    picture = store.unexaminable_picture

    assert_equal "cpython 3.12 cc", picture.fetch(:machine)
    assert_equal [{ package: "wrapt", release: "wrapt 1.13.3",
                    reason: "could not install wrapt==1.13.3: no matching distribution" }],
      picture.fetch(:records)
  end

  def test_a_picture_from_another_machine_is_not_reported_as_this_ones_failure
    # The same rule `unexaminable` applies to a sentence, applied to the record. An image bump
    # re-opens every fact the old stamp established, and reporting them as this machine's would
    # settle the very crossing that just became worth trying — with the service believing a fact its
    # own sender has stopped counting.
    store = Ledger.new
    store.machine = "cpython 3.12 cc"
    store.record_pair("wrapt", "1.13.3", "1.14.0", outcome: Ledger::UNEXAMINABLE,
      release: "wrapt 1.13.3", now: 100.0)
    store.machine = "cpython 3.13 cc"

    picture = store.unexaminable_picture

    assert_equal "cpython 3.13 cc", picture.fetch(:machine)
    assert_empty picture.fetch(:records)
  end

  def test_a_picture_carries_a_failure_that_never_named_a_release_under_its_pair
    # A failure raised before the installer said which release it was about still says this pair
    # cannot be examined. Dropping it would make the one fact the ledger holds about that crossing
    # the one fact the service is never told, and the queue would go on offering it.
    store = Ledger.new
    store.machine = "cpython 3.12 cc"
    store.record_pair("wrapt", "1.13.3", "1.14.0", outcome: Ledger::UNEXAMINABLE, now: 100.0)

    picture = store.unexaminable_picture

    assert_equal [{ package: "wrapt", release: "1.13.3->1.14.0", reason: "" }],
      picture.fetch(:records)
  end

  def test_a_release_refused_without_a_compiler_is_asked_again_when_one_arrives
    # The half of the stamp that is not an interpreter, and the reason it is there.
    #
    # `prism`, `bigdecimal`, `json`, `psych`, `date`, `nio4r`, `msgpack` and `racc` publish no
    # linux build at all (asked of the index, not assumed), so on this deployment 862 of the Ruby
    # ledger's 1,844 pairs were settled unbuildable — and every one of them was a fact about the
    # *image*. Without the toolchain in the stamp, adding a compiler would leave all 862 settled
    # for ever, which is the failure this pins: the same interpreter, a different toolchain, an
    # open question.
    store = Ledger.new
    store.machine = "ruby 3.3.12 no-cc"
    store.record_pair(
      "rubyXL", "3.3.33", "3.4.38",
      outcome: Ledger::UNEXAMINABLE,
      note: "installing rubyXL 3.3.33 failed: make failedNo such file or directory - make",
      release: "rubyXL 3.3.33", now: 100.0
    )
    assert store.settled_pair?("rubyXL", "3.3.33", "3.4.38")

    # The image gains a compiler. Same interpreter, so a stamp that named only the interpreter
    # would keep the gem settled — and never examined — for ever.
    store.machine = "ruby 3.3.12 cc"
    refute store.settled_pair?("rubyXL", "3.3.33", "3.4.38")
    assert store.due?("rubyXL", "3.3.33", "3.4.38", now: 1_000.0)
    assert_empty store.unexaminable("rubyXL")
  end

  def test_an_unbuildable_release_settles_every_crossing_through_it
    # The record is per pair because a pair is what was attempted; the fact is per release.
    # `wrapt 1.13.3` is the old side of `1.13.2->1.13.3` and the new side of `1.13.3->1.14.0`,
    # and both are settled by one failure — otherwise the schedule asks pip about the same
    # release once per crossing, which is eleven more pair slots spent on work that cannot
    # happen.
    store = Ledger.new
    store.record_pair(
      "wrapt", "1.13.3", "1.14.0",
      outcome: Ledger::UNEXAMINABLE,
      note: "could not install wrapt==1.13.3: no matching distribution",
      release: "wrapt 1.13.3", now: 100.0
    )

    assert store.settled_pair?("wrapt", "1.13.2", "1.13.3")
    assert store.settled_pair?("wrapt", "1.13.3", "1.15.0")
    refute store.due?("wrapt", "1.13.2", "1.13.3", now: 1_000.0)
    # And a crossing that does not run through the release at all is still work.
    refute store.settled_pair?("wrapt", "1.14.0", "1.15.0")
  end

  def test_clearing_an_unbuildable_release_gives_its_crossings_back
    # The repair for a fixed environment, and the reason the index is derived rather than stored:
    # dropping the record is the whole of it.
    store = Ledger.new
    store.record_pair("wrapt", "1.13.3", "1.14.0", outcome: Ledger::UNEXAMINABLE,
      release: "wrapt 1.13.3", now: 100.0)
    assert store.settled_pair?("wrapt", "1.13.2", "1.13.3")

    store.pairs.delete("wrapt 1.13.3->1.14.0")
    store.unbuildable_index = nil

    refute store.settled_pair?("wrapt", "1.13.2", "1.13.3")
    assert store.due?("wrapt", "1.13.2", "1.13.3", now: 1_000.0)
  end

  def test_the_yield_of_a_package_is_its_own_work_not_another_package_s
    # `httpx` and `httpx-sse` share a prefix, and a counter that confused them would tell the
    # planner one package was producing while the other was not.
    store = Ledger.new
    store.record_pair("httpx", "0.27.2", "0.28.1", outcome: Ledger::DONE, findings: 4, now: 1.0)
    store.record_pair("httpx-sse", "0.4.0", "0.4.2", outcome: Ledger::EMPTY, now: 1.0)

    assert_equal 4, store.yielded("httpx")
    assert_equal 0, store.yielded("httpx-sse")
    assert_equal 1, store.settled("httpx")
  end

  def test_a_report_that_was_answered_is_not_answered_again
    store = Ledger.new
    store.record_report("abc", outcome: Ledger::PROPOSED, now: 100.0)

    assert store.settled_report?("abc")
    refute store.due_report?("abc", now: 1_000.0)
  end

  def test_the_cursor_travels_with_the_work_it_describes
    # A cursor advanced separately from the ledger can point past a report the work never
    # reached, which is a report the miner would never see again.
    store = Ledger.new(cursor_since: "2026-01-01T00:00:00Z",
      cursor_id: "00000000-0000-0000-0000-000000000001")
    again = Ledger.from_json(store.to_h)

    assert_equal store.cursor_since, again.cursor_since
    assert_equal store.cursor_id, again.cursor_id
  end

  def test_a_ledger_is_written_whole_or_not_at_all
    # Written to a neighbour and renamed, so a crash cannot leave a truncated ledger that reads
    # as "you have done nothing".
    path = @home + "ledger.json"
    store = Ledger.new
    store.record_pair("httpx", "0.27.2", "0.28.1", outcome: Ledger::DONE, findings: 4, now: 1.0)
    Ledger.save(store, path)

    assert_empty Dir.glob(@home.join("*.tmp").to_s)
    assert_equal 4, Ledger.load(path).yielded("httpx")
  end

  def test_an_unreadable_ledger_is_set_aside_rather_than_deleted
    # The bug that wrote it is worth looking at, and the miner still has to run.
    path = write("ledger.json", "{not json")

    assert_empty Ledger.load(path).pairs
    aside = Dir.glob(@home.join("ledger.json.unreadable-*").to_s)
    assert_equal 1, aside.length
    assert_equal "{not json", File.read(aside.first)
  end

  def test_a_ledger_from_a_future_version_is_refused_rather_than_guessed_at
    # A wrong parse would either redo months of work or, far worse, report it done. Refusing is
    # the only safe read.
    payload = Ledger.new.to_h
    payload["schema_version"] = Ledger::SCHEMA_VERSION + 1

    error = assert_raises(ArgumentError) { Ledger.from_json(payload) }
    assert_includes error.message, "schema"
  end

  def test_a_refused_ledger_is_a_clean_start_rather_than_a_crash
    path = write("ledger.json", JSON.generate({ "schema_version" => 99, "pairs" => {} }))

    assert_empty Ledger.load(path).pairs
    refute_empty Dir.glob(@home.join("ledger.json.unreadable-*").to_s)
  end

  def test_a_release_fact_is_scoped_to_the_machine_that_established_it
    # A release fact is about a release *and* about the machine that tried it, the same as an
    # `unexaminable` pair — but the verifier's `releases` map carried no stamp, so an sdist
    # refused for having no `cp312` wheel stayed refused after the image moved on, and every
    # report that shared the release was skipped for ever on a fact that had stopped being true.
    store = Ledger.new
    store.machine = "cpython 3.12 cc"
    store.record_release("kombu 4.1.0", "no wheel for this interpreter")

    assert_equal "no wheel for this interpreter", store.cannot_build("kombu 4.1.0")
    assert_equal "cpython 3.12 cc", store.release_interpreters["kombu 4.1.0"]

    # The image moves on, and the question is open again rather than settled for ever.
    store.machine = "cpython 3.13 cc"
    assert_nil store.cannot_build("kombu 4.1.0")
  end

  def test_a_release_fact_is_answered_for_the_index_the_caller_names
    store = Ledger.new
    store.machine = "cpython 3.12 cc"
    store.record_release("racc 1.8.1", "no compiler here", machine: "ruby 3.3.12 no-cc")

    assert_equal "no compiler here",
      store.cannot_build("racc 1.8.1", machine: "ruby 3.3.12 no-cc")
    # The same machine with a compiler is a different question, and a different index is a
    # different machine.
    assert_nil store.cannot_build("racc 1.8.1", machine: "ruby 3.3.12 cc")
    assert_nil store.cannot_build("racc 1.8.1")
  end

  def test_a_release_fact_with_no_stamp_still_counts
    # A ledger written before the stamp existed has `releases` and nothing beside it. Reading an
    # absent stamp as anything but "this interpreter" would distrust every fact established a
    # moment ago on the machine asking — which is the work the field exists to avoid.
    store = Ledger.new
    store.releases["wrapt 1.13.3"] = "no matching distribution"

    assert_equal "no matching distribution", store.cannot_build("wrapt 1.13.3")
  end

  def test_the_release_stamp_survives_a_round_trip
    # The stamp is only worth anything if it is stored: an in-memory-only field would be gone by
    # the next restart, which is exactly when it matters.
    path = @home + "ledger.json"
    store = Ledger.new
    store.record_release("kombu 4.1.0", "no wheel for this interpreter")
    Ledger.save(store, path)

    again = Ledger.load(path)
    assert_equal "no wheel for this interpreter", again.cannot_build("kombu 4.1.0")
    assert_equal Ledger::MACHINE, again.release_interpreters["kombu 4.1.0"]
  end

  def test_a_pair_stamped_before_the_toolchain_was_named_still_reads
    # The field was called `interpreter`, and the value named half the machine.
    #
    # A ledger written then must load — refusing it would set aside months of settled work — and
    # its *value* must be kept as it was rather than upgraded, because a fact established on a
    # machine with no compiler is exactly the kind of fact the machine with one needs to re-open.
    path = @home + "ledger.json"
    payload = Ledger.new.to_h
    payload["pairs"] = {
      "wrapt 1.13.3->1.14.0" => {
        "outcome" => Ledger::UNEXAMINABLE,
        "note" => "could not install wrapt==1.13.3: no matching distribution",
        "release" => "wrapt 1.13.3",
        "interpreter" => "cpython 3.11"
      }
    }
    path.write(JSON.generate(payload))

    again = Ledger.load(path)
    record = again.pair("wrapt", "1.13.3", "1.14.0")
    refute_nil record
    assert_equal "cpython 3.11", record.machine
    refute again.settled_pair?("wrapt", "1.13.3", "1.14.0")
  end

  def test_a_ledger_written_before_the_stamp_existed_still_loads
    # Additive with a default, so no schema bump: bumping would have set every existing ledger
    # aside and redone months of settled work.
    payload = Ledger.new.to_h
    payload.delete("release_interpreters")
    payload["releases"] = { "kombu 4.1.0" => "no wheel for this interpreter" }

    again = Ledger.from_json(payload)
    assert_equal "no wheel for this interpreter", again.cannot_build("kombu 4.1.0")
  end

  def test_the_ecosystem_the_feed_carried_survives_a_round_trip
    # Additive, like the status map: a ledger written before the field existed has no answer, and
    # the reader must fetch the body rather than guess Python and drop the wrong index.
    store = Ledger.new
    store.note_seen("a", now: 1.0, ecosystem: "ruby")

    assert_equal "ruby", Ledger.from_json(store.to_h).ecosystem_of("a")

    payload = store.to_h
    payload.delete("report_ecosystems")
    assert_equal "", Ledger.from_json(payload).ecosystem_of("a")
  end

  def test_a_report_settles_after_its_own_ceiling
    # The ceiling is named for reports now, and it did not move: a report checked
    # `MAX_REPORT_ATTEMPTS` times is left alone whatever the last attempt said.
    store = Ledger.new
    Ledger::MAX_REPORT_ATTEMPTS.times do
      store.record_report("abc", outcome: Ledger::FAILED, now: 100.0)
    end

    assert store.settled_report?("abc")
    refute store.due_report?("abc", now: 1_000.0)
  end

  def test_the_derived_totals_are_the_numbers_the_separate_scans_produced
    # The schedule ordered by three walks of the ledger and now orders by one derived index.
    # This pins that the index answers exactly what the walks did, on a ledger built to disagree
    # with a lazier derivation: a package that found nothing, one whose releases cannot be built
    # here, one sharing a prefix with another, one that only failed, and one the ledger has
    # never heard of.
    store = Ledger.new
    store.record_pair("httpx", "0.27.2", "0.28.1", outcome: Ledger::DONE, findings: 4, now: 10.0)
    store.record_pair("httpx", "0.28.0", "0.28.1", outcome: Ledger::EMPTY, now: 30.0)
    store.record_pair("httpx-sse", "0.4.0", "0.4.2", outcome: Ledger::EMPTY, now: 20.0)
    store.record_pair("wrapt", "1.13.3", "1.14.0", outcome: Ledger::UNEXAMINABLE,
      release: "wrapt 1.13.3", now: 40.0)
    store.record_pair("numpy", "2.0.0", "2.1.0", outcome: Ledger::FAILED, next_at: 99.0,
      now: 50.0)

    ["httpx", "httpx-sse", "wrapt", "numpy", "click"].each do |package|
      totals = store.package_totals(package)
      assert_equal scans(store, package), [totals.settled, totals.yielded, totals.last], package
    end
  end

  def test_a_derived_total_is_dropped_when_a_pair_is_recorded
    # The index is a read of the pairs, so a write has to drop it. A stale copy would make the
    # schedule order by work the ledger no longer describes.
    store = Ledger.new
    store.record_pair("httpx", "0.27.2", "0.28.1", outcome: Ledger::DONE, findings: 4, now: 10.0)
    assert_equal 4, store.package_totals("httpx").yielded

    store.record_pair("httpx", "0.28.0", "0.28.1", outcome: Ledger::DONE, findings: 2, now: 20.0)

    totals = store.package_totals("httpx")
    assert_equal 2, totals.settled
    assert_equal 6, totals.yielded
    assert_equal 20.0, totals.last
  end

  def test_a_loaded_ledger_derives_the_same_totals
    # The index is derived rather than stored, so a restart is not a fresh start: a ledger read
    # back from disk answers the same numbers the one that wrote it did.
    path = @home + "ledger.json"
    store = Ledger.new
    store.record_pair("httpx", "0.27.2", "0.28.1", outcome: Ledger::DONE, findings: 4, now: 10.0)
    Ledger.save(store, path)

    assert_equal Ledger::PackageTotals.new(settled: 1, yielded: 4, last: 10.0),
      Ledger.load(path).package_totals("httpx")
  end

  private

  # The three readings the ledger used to make, each walking every pair.
  #
  # Kept as a walk rather than as a second call into the code under test: an index checked
  # against itself agrees with itself, which is the shape of a test that proves nothing.
  def scans(store, package)
    prefix = "#{package} "
    settled = store.pairs.count do |key, record|
      key.start_with?(prefix) && Ledger::SETTLED_PAIR.include?(record.outcome)
    end
    found = store.pairs.sum do |key, record|
      key.start_with?(prefix) && Ledger::SETTLED_PAIR.include?(record.outcome) ? record.findings : 0
    end
    stamps = store.pairs.filter_map do |key, record|
      record.at if key.start_with?(prefix) && record.at != 0.0
    end
    [settled, found, stamps.max || 0.0]
  end
end
