# frozen_string_literal: true

require "date"

require_relative "test_helper"

# Clustering and summarising: the rules that decide what one finding is.
#
# Every assertion here is about a fact the differential established by execution, and several of
# them are regressions from the live corpus — `paramiko`'s `DSSKey` filed as a rename to
# `ECDSAKey`, `pandas`'s `delim_whitespace` filed as `delimiter`, `wsproto.Event` filed as a
# removal, `toml.InlineTableDict` filed as a removal. The comments say which, because a future
# change that reads as a tidy-up is the change that re-files them.
class FindingsTest < MinerTest
  MECHANISM = AgentsMiner::Mechanism
  OBSERVATION = AgentsMiner::Observation

  def an_observation(**overrides)
    fields = {
      symbol: "Client",
      parameter: "proxies",
      exception: "TypeError: Client.__init__() got an unexpected keyword argument 'proxies'",
      accepted_before: true,
      accepted_after: false,
      repair: "proxy"
    }.merge(overrides)
    OBSERVATION.new(**fields)
  end

  def symbol_observation(name, repair = nil, refused = nil, moved = nil)
    OBSERVATION.new(
      symbol: name,
      parameter: "",
      exception: "AttributeError: module 'numpy' has no attribute '#{name}'",
      accepted_before: true,
      accepted_after: false,
      repair: repair,
      candidate: refused,
      moved: moved,
      traceback: "AttributeError: module 'numpy' has no attribute '#{name}'",
      kind: "symbol"
    )
  end

  def test_call_sites_sharing_a_mechanism_become_one_finding
    # The whole reason clustering exists: one release decision, many call sites.
    groups = cluster([an_observation(symbol: "Client"), an_observation(symbol: "get"),
                      an_observation(symbol: "post")])

    assert_equal 1, groups.size
    assert_equal %w[Client get post].sort, groups[0].map(&:symbol).sort
  end

  def test_a_different_parameter_is_a_different_finding
    # `cert` and `proxies` were both removed in the same release, and neither explains the other,
    # so collapsing them would hide the second.
    groups = cluster([an_observation(parameter: "proxies"),
                      an_observation(parameter: "cert", repair: nil)])

    assert_equal 2, groups.size
  end

  def test_a_parameter_the_old_release_also_refused_is_not_a_break
    # Never-there is not taken-away. This is the rule that keeps the differential honest when a
    # signature diff reports a name that was never accepted.
    assert_empty cluster([an_observation(accepted_before: false)])
  end

  def test_a_parameter_the_new_release_still_accepts_is_not_a_break
    assert_empty cluster([an_observation(accepted_after: true)])
  end

  def test_a_renamed_argument_reports_the_name_the_new_release_accepted
    finding = summarise("httpx", "0.28.1", "0.27.2", [an_observation])

    assert_equal MECHANISM::PARAMETER_RENAMED, finding.mechanism
    assert_equal "httpx 0.28.1 renamed proxies= to proxy=", finding.title
    assert_includes finding.resolution, "`proxies=` is `proxy=`"
  end

  def test_a_removed_argument_says_no_parameter_is_a_close_match
    # The honest report when introspection found nothing: this is not a rename. Saying only "it was
    # removed" would leave a reader looking for a rename.
    finding = summarise("httpx", "0.28.1", "0.27.2",
      [an_observation(parameter: "app", repair: nil)])

    assert_equal MECHANISM::PARAMETER_REMOVED, finding.mechanism
    assert_equal "httpx 0.28.1 removed the app= argument", finding.title
    assert_includes finding.resolution, "not a rename"
  end

  def test_a_candidate_that_was_refused_is_named_as_refused_not_as_the_fix
    # The report a live corpus got wrong: `pandas` dropped `delim_whitespace=` and still has a
    # `delimiter=`, which `difflib` offered and the interpreter refused, because a boolean flag and
    # a separator string are not the same argument. Filed as a rename, this told callers to pass
    # `True` where a string is expected.
    finding = summarise("pandas", "3.0.6", "2.3.3",
      [an_observation(parameter: "delim_whitespace", repair: nil,
        candidate: "delimiter")])

    assert_equal MECHANISM::PARAMETER_REMOVED, finding.mechanism
    assert_equal "pandas 3.0.6 removed the delim_whitespace= argument", finding.title
    assert_nil finding.replacement
    assert_equal "delimiter", finding.refused_candidate
    assert_includes finding.resolution, "executed in its place and refused"
  end

  def test_the_count_of_call_sites_is_carried_into_the_report
    finding = summarise("httpx", "0.28.1", "0.27.2",
      [an_observation(symbol: "Client"), an_observation(symbol: "get")])

    assert_equal 2, finding.call_sites
    assert_equal 2, finding.repaired_call_sites
    assert_includes finding.problem, "2 call sites"
  end

  def test_the_evidence_names_every_call_site_the_mechanism_broke
    finding = summarise("httpx", "0.28.1", "0.27.2",
      [an_observation(symbol: "Client"), an_observation(symbol: "get")])

    assert_includes finding.problem, "Client(proxies=…)"
    assert_includes finding.problem, "get(proxies=…)"
  end

  def test_a_single_call_site_is_not_reported_as_call_sites
    # The prose is read by people; `1 call sites` reads as a bug in the tool.
    finding = summarise("httpx", "0.28.1", "0.27.2", [an_observation])

    assert_includes finding.problem, "1 call site "
    refute_includes finding.problem, "1 call sites"
  end

  def test_the_trace_filed_is_the_one_the_interpreter_printed
    # Not a rendering of it. A report whose evidence the miner composed would be a claim about a
    # failure rather than the failure.
    real = "Traceback (most recent call last):\n  " \
           "File \"call_site.py\", line 3, in <module>\n    " \
           "httpx.Client(proxies='_marker')\n" \
           "TypeError: Client.__init__() got an unexpected keyword argument 'proxies'"
    finding = summarise("httpx", "0.28.1", "0.27.2", [an_observation(traceback: real)])

    assert_equal real, finding.trace
  end

  def test_a_refused_candidate_is_a_different_finding_from_the_fix_that_worked
    # Two call sites, two answers, and one report cannot carry both. Merging them quoted the
    # refusal under a fix that had been executed — the shape that shipped a wrong answer with a
    # real citation attached.
    groups = cluster(
      [
        an_observation(parameter: "", symbol: "AsyncClient", kind: "symbol", repair: nil,
          candidate: "proxy"),
        an_observation(parameter: "", symbol: "Client", kind: "symbol", repair: "proxy")
      ]
    )

    assert_equal 2, groups.size
    fixed = summarise("httpx", "0.28.1", "0.27.2", groups[1])
    refused = summarise("httpx", "0.28.1", "0.27.2", groups[0])
    assert_equal MECHANISM::SYMBOL_RENAMED, fixed.mechanism
    assert_equal MECHANISM::SYMBOL_REMOVED, refused.mechanism
    assert_equal "httpx 0.28.1 removed httpx.AsyncClient", refused.title
  end

  def test_a_finding_is_serialisable_as_json
    # It travels to the corpus as a request body, so it has to survive the trip.
    finding = summarise("httpx", "0.28.1", "0.27.2", [an_observation])

    assert_kind_of AgentsMiner::Finding, finding
    assert_equal "httpx", finding.to_h["library"]
  end

  def test_the_title_never_exceeds_what_a_report_can_hold
    # A report's title is bounded at 300 characters; a finding that exceeded it would be refused by
    # the corpus after the work of mining it.
    finding = summarise("a" * 400, "0.28.1", "0.27.2", [an_observation(parameter: "p" * 200)])

    assert_operator finding.title.length, :<=, 300
  end

  def test_a_finding_carries_no_notion_of_today
    # Findings are derived from two releases and nothing else, so a run is reproducible: a
    # timestamp here would make two runs over the same pair differ.
    finding = summarise("httpx", "0.28.1", "0.27.2", [an_observation])

    refute_includes JSON.generate(finding.to_h), Date.today.year.to_s
  end

  def test_a_removed_exported_name_is_a_finding_of_its_own
    # An argument and a symbol are different failures for a caller: a keyword at a call site, a
    # name at an import. Filing them as one mechanism would put the fix for one under the other.
    removed = summarise("numpy", "2.0.0", "1.26.4", cluster([symbol_observation("float_")])[0])

    assert_equal MECHANISM::SYMBOL_REMOVED, removed.mechanism
    assert_equal "numpy 2.0.0 removed numpy.float_", removed.title
    assert_equal "", removed.parameter
    assert_nil removed.replacement
  end

  def test_a_removal_with_nothing_offered_says_what_was_searched
    # A reader has to be able to tell "nothing matched" from "the near name was tried and is broken
    # too" — the two look identical from outside, and only the second means the replacement is
    # further away than it looks.
    argument = summarise("httpx", "0.28.1", "0.27.2",
      [an_observation(parameter: "app", repair: nil)])
    assert_includes argument.resolution, "`app=` is gone in httpx 0.28.1"

    symbol = summarise("numpy", "2.0.0", "1.26.4", cluster([symbol_observation("float_")])[0])

    assert_includes symbol.resolution, "The release exports no name built from the same words"
    refute_includes symbol.resolution, "executed in its place and refused"
  end

  def test_a_refused_symbol_candidate_is_named_in_the_removal
    finding = summarise("numpy", "2.0.0", "1.26.4",
      cluster([symbol_observation("RankWarning", nil, "hanning")])[0])

    assert_equal MECHANISM::SYMBOL_REMOVED, finding.mechanism
    assert_nil finding.replacement
    assert_equal "hanning", finding.refused_candidate
    assert_includes finding.resolution,
      "`hanning`, the closest there is to it, was executed in its place and refused"
  end

  def test_a_renamed_argument_does_not_claim_the_value_means_the_same
    # The differential establishes that a keyword is accepted, and a probe that passes a
    # placeholder cannot establish more. `pandas` dropped `delim_whitespace=` — a flag — and has a
    # `delimiter=` that takes a string.
    finding = summarise("pandas", "3.0.6", "2.3.3",
      [an_observation(parameter: "delim_whitespace")])

    assert_equal MECHANISM::PARAMETER_RENAMED, finding.mechanism
    assert_includes finding.resolution, "establishes the name and not the meaning"
  end

  def test_a_moved_name_says_where_it_is_now_rather_than_pinning
    # The audit that found this filed it as a removal, whose advice — pin below this release —
    # is wrong: the caller's import is one path segment away from working.
    finding = summarise("wsproto", "1.3.2", "1.2.0",
      cluster([symbol_observation("Event", nil, nil, "wsproto.events.Event")])[0])

    assert_equal MECHANISM::SYMBOL_MOVED, finding.mechanism
    assert_equal "wsproto 1.3.2 moved wsproto.Event to wsproto.events.Event", finding.title
    assert_equal "wsproto.events.Event", finding.moved
    assert_nil finding.replacement
    assert_includes finding.resolution, "Import it from where it lives now"
    refute_includes finding.resolution.downcase, "pin"
  end

  def test_a_renamed_name_says_which_name_replaced_it
    finding = summarise("numpy", "2.0.0", "1.26.4",
      cluster([symbol_observation("float_", "float64")])[0])

    assert_equal MECHANISM::SYMBOL_RENAMED, finding.mechanism
    assert_includes finding.title, "renamed numpy.float_ to float64"
    assert_includes finding.resolution, "`float_` is `float64`"
    assert_equal "float64", finding.replacement
  end

  def test_a_name_removed_by_paramiko_is_not_reported_as_the_ecdsa_key_class
    # From the live corpus, and the worst of them: `paramiko` 4.0.0 dropped `DSSKey`, the DSA key
    # class, and the miner filed that it had been renamed to `ECDSAKey`. Both are key classes and
    # both end in "Key", so `difflib` scored them 0.71 — and the advice is to change which
    # cryptography a caller uses. The exception's own text disagreed with the report as well.
    finding = summarise("paramiko", "4.0.0", "3.5.1", cluster([symbol_observation("DSSKey")])[0])

    assert_equal MECHANISM::SYMBOL_REMOVED, finding.mechanism
    assert_equal "paramiko 4.0.0 removed paramiko.DSSKey", finding.title
    assert_nil finding.replacement
    refute_includes finding.title, "renamed"
    assert_includes finding.resolution, "not a rename"
  end

  def test_an_argument_and_a_name_with_the_same_spelling_are_two_findings
    # `values=` and `values` are different things a release can take away, and a cluster key that
    # ignored the kind would merge them into one report whose fix is right for half its readers.
    argument = OBSERVATION.new(
      symbol: "Session", parameter: "values", exception: "TypeError",
      accepted_before: true, accepted_after: false
    )
    groups = cluster([argument, symbol_observation("values")])

    assert_equal 2, groups.size

    findings = groups.map { |group| summarise("pkg", "2.0", "1.0", group) }
    assert_equal [MECHANISM::PARAMETER_REMOVED, MECHANISM::SYMBOL_REMOVED].sort,
      findings.map(&:mechanism).sort
  end

  def test_a_symbol_finding_says_the_reference_resolved_before_it_broke
    finding = summarise("numpy", "2.0.0", "1.26.4", cluster([symbol_observation("float_")])[0])

    assert_includes finding.problem, "resolved on 1.26.4"
    assert_includes finding.problem, "numpy.float_"
  end

  private

  def cluster(observations) = AgentsMiner.cluster(observations)

  def summarise(library, version, from_version, group, ecosystem: "python")
    AgentsMiner.summarise(library, version, from_version, group, ecosystem: ecosystem)
  end
end
