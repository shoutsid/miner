# frozen_string_literal: true

require_relative "test_helper"
require_relative "stub_helper"

# Reading the reviewed advisories.
#
# Three things have to stay true about a lead and all three are asserted here: it is keyed by gem
# rather than being a finding, a withdrawn or non-RubyGems record produces nothing at all, and the
# picture is cache-first so a restart or a cycle does not depend on GitHub being up. The one seam
# that touches the network is `fetch_page`, and every test that would reach it places a document
# instead — the same shape `ruby_versions_test.rb` uses.
class AdvisoriesTest < MinerTest
  include StubHelper

  A = AgentsFyiMiner::Advisories

  def advisory(**overrides)
    {
      "ghsa_id" => "GHSA-aaaa-bbbb-cccc",
      "html_url" => "https://github.com/advisories/GHSA-aaaa-bbbb-cccc",
      "summary" => "Rack is vulnerable to something",
      "severity" => "high",
      "published_at" => "2026-01-01T00:00:00Z",
      "updated_at" => "2026-01-02T00:00:00Z",
      "github_reviewed_at" => "2026-01-03T00:00:00Z",
      "withdrawn_at" => nil,
      "cvss" => { "score" => 7.5, "vector_string" => "CVSS:3.1/AV:N" },
      "cwes" => [{ "cwe_id" => "CWE-200", "name" => "Exposure" }],
      "identifiers" => [{ "type" => "GHSA", "value" => "GHSA-aaaa-bbbb-cccc" },
                        { "type" => "CVE", "value" => "CVE-2026-1" }],
      "vulnerabilities" => [
        { "package" => { "ecosystem" => "rubygems", "name" => "rack" },
          "first_patched_version" => "2.2.6.1", "vulnerable_version_range" => "< 2.2.6.1" }
      ]
    }.merge(overrides)
  end

  # One advisory, one lead, and every field the service stores carried across: the id, the fix, the
  # severity GitHub assigned and the CVE alias a caller may be holding instead of the GHSA id.
  def test_a_reviewed_advisory_becomes_one_lead_per_rubygems_package
    leads = A.leads_from(advisory)

    assert_equal 1, leads.length
    lead = leads.first
    assert_equal "rack", lead["library"]
    assert_equal "GHSA-aaaa-bbbb-cccc", lead["advisory_id"]
    assert_equal "high", lead["severity"]
    assert_equal "2.2.6.1", lead["fixed_in"]
    assert_equal ["CVE-2026-1"], lead["aliases"]
    assert_equal ["CWE-200"], lead["cwe_ids"]
    assert_equal 7.5, lead["cvss_score"]
    assert_equal "https://github.com/advisories/GHSA-aaaa-bbbb-cccc", lead["source_url"]
    assert_equal "2026-01-03T00:00:00Z", lead["reviewed_at"]
  end

  # An advisory that names two gems is two leads, because the service keys its rows by
  # `(library, advisory_id)` — one package affected twice and two packages affected once are
  # different pictures.
  def test_an_advisory_naming_two_gems_is_two_leads
    leads = A.leads_from(advisory("vulnerabilities" => [
      { "package" => { "ecosystem" => "rubygems", "name" => "rack" },
        "first_patched_version" => "2.2.6.1" },
      { "package" => { "ecosystem" => "rubygems", "name" => "rack-test" },
        "first_patched_version" => "2.1.0" }
    ]))

    assert_equal %w[rack rack-test], leads.map { |lead| lead["library"] }
  end

  # **One advisory can carry several ranges for the same gem**, because GitHub lists a separate
  # `vulnerabilities` entry per affected version line — and the service's key is
  # `(library, advisory_id)`, so they are one row. This is the bug a live read caught: the body was
  # refused as a duplicate at position six before it reached the service. A lead carrying a fix is
  # preferred over one that does not, because the fix is the half the planner acts on.
  def test_several_ranges_for_one_gem_collapse_to_one_lead_with_a_fix
    leads = A.leads_from(advisory("vulnerabilities" => [
      { "package" => { "ecosystem" => "rubygems", "name" => "spree_api" } },
      { "package" => { "ecosystem" => "rubygems", "name" => "spree_api" },
        "first_patched_version" => "4.7.4" }
    ]))

    assert_equal 1, leads.length
    assert_equal "spree_api", leads.first["library"]
    assert_equal "4.7.4", leads.first["fixed_in"]
  end

  # A retraction is not a lead. The service's picture write would drop it anyway, but a client that
  # never sends one is a client whose absence is honest rather than a claim about a fix that was
  # taken back.
  def test_a_withdrawn_advisory_produces_nothing
    assert_empty A.leads_from(advisory("withdrawn_at" => "2026-02-01T00:00:00Z"))
  end

  # The API answers the RubyGems filter with a RubyGems-first set, and a record that also touches
  # another ecosystem must not become a gem named the same way.
  def test_a_record_naming_only_another_ecosystem_produces_nothing
    other = advisory("vulnerabilities" => [
      { "package" => { "ecosystem" => "npm", "name" => "rack" },
        "first_patched_version" => "1.0.0" }
    ])

    assert_empty A.leads_from(other)
  end

  # A word this build does not understand is dropped rather than sent: the service validates the
  # four GitHub uses and would refuse the whole body over one it does not know, and no severity is
  # better than a picture that cannot be read.
  def test_an_unrecognised_severity_is_dropped_rather_than_sent
    refute A.leads_from(advisory("severity" => "catastrophic")).first.key?("severity")
    refute A.leads_from(advisory("severity" => nil)).first.key?("severity")
  end

  # **The middle severity is the API's word, and it is `medium`, not the OSV archive's `moderate`.**
  # This is the bug a live read caught: a vocabulary copied from the other access path dropped 539 of
  # the reviewed set silently — they arrived as advisories with no severity at all, which reads as
  # "the source recorded none" rather than "this client could not spell it".
  def test_the_middle_severity_is_the_apis_word
    assert_equal "medium", A.leads_from(advisory("severity" => "medium")).first["severity"]
  end

  # An advisory with no fix still becomes a lead — it orders the package — and its `fixed_in` is
  # absent rather than a version nobody stated.
  def test_an_advisory_with_no_fix_is_a_lead_with_no_target
    lead = A.leads_from(advisory("vulnerabilities" => [
      { "package" => { "ecosystem" => "rubygems", "name" => "rack" } }
    ])).first

    assert_nil lead["fixed_in"]
  end

  def test_the_leads_group_by_gem_for_the_planner
    leads = [A.leads_from(advisory).first,
             A.leads_from(advisory("ghsa_id" => "GHSA-zzzz-yyyy-xxxx")).first,
             A.leads_from(advisory("vulnerabilities" => [
               { "package" => { "ecosystem" => "rubygems", "name" => "puma" },
                 "first_patched_version" => "6.4.0" }
             ])).first]

    grouped = A.leads_by_library(leads)

    assert_equal %w[puma rack], grouped.keys.sort
    assert_equal 2, grouped.fetch("rack").length
  end

  # The picture is read once and served from the cache afterwards: a cycle in which GitHub is
  # unreachable is a cycle that still plans with what it has, which is the rule the breadth ranking
  # already keeps.
  def test_a_picture_is_fetched_once_and_read_from_the_cache_after
    calls = []
    with_stub(A, :fetch_page, lambda { |url|
      calls << url
      [[advisory], nil]
    }) do
      first = A.picture(cache: @home + "index")
      second = A.picture(cache: @home + "index")

      assert_equal first, second
      assert_equal 1, first.length
      assert_equal 1, calls.length
      assert A.cache_path(@home + "index").file?
    end
  end

  # A stale cache and an unreadable source is the cache, not a failure: a miner that stopped because
  # GitHub had an afternoon would be trading a certain loss for an uncertain one.
  def test_a_stale_cache_is_used_when_the_source_cannot_be_read
    write("index/advisories-ruby.json", A.leads_from(advisory))
    with_stub(A, :fetch_page, ->(_url) { raise A::IndexError.new("boom", code: 500) }) do
      leads = A.picture(cache: @home + "index", max_age: 0)

      assert_equal 1, leads.length
      assert_equal "rack", leads.first.fetch("library")
    end
  end

  # No cache and no source is a failure, and it propagates: the service loop logs it and plans with
  # no leads, which is what it did before advisories existed.
  def test_an_unreadable_source_with_no_cache_raises
    with_stub(A, :fetch_page, ->(_url) { raise A::IndexError.new("boom", code: 503) }) do
      assert_raises(A::IndexError) { A.picture(cache: @home + "index") }
    end
  end

  # The set is paged, and a page that says there is another is followed rather than dropped — a
  # picture that stopped at the first hundred would be missing most of the reviewed set.
  def test_paging_follows_the_link_header
    responses = [
      [[advisory], '<https://api.github.test/advisories?page=2>; rel="next"'],
      [[advisory("ghsa_id" => "GHSA-zzzz-yyyy-xxxx",
        "html_url" => "https://github.com/advisories/GHSA-zzzz-yyyy-xxxx")], nil]
    ]
    with_stub(A, :fetch_page, ->(_url) { responses.shift }) do
      leads = A.fetch_picture

      assert_equal 2, leads.length
      assert_equal %w[GHSA-aaaa-bbbb-cccc GHSA-zzzz-yyyy-xxxx],
        leads.map { |lead| lead["advisory_id"] }
    end
  end
end
