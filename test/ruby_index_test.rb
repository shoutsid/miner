# frozen_string_literal: true

require_relative "test_helper"

# What each release of a gem *declares*, read from the compact index.
#
# The parser is the substance, and it is driven against lines copied out of the real document
# — `devise`'s own, with the `&`-joined requirement, a release with no dependencies and the
# checksum trailer — because the format belongs to a third party and a fixture invented beside
# the reader would agree with whatever the reader does.
class RubyIndexTest < MinerTest
  INDEX = AgentsFyiMiner::RubyIndex

  # Verbatim from `https://index.rubygems.org/info/devise`.
  DEVISE = <<~DOCUMENT
    ---
    0.1.0 warden:~> 0.10.7|checksum:aaaa,created_at:2009-01-01T00:00:00Z
    2.2.4 bcrypt-ruby:~> 3.0,orm_adapter:~> 0.1,railties:~> 3.1,warden:~> 1.2.1|checksum:bbbb,created_at:2013-05-07T15:54:34Z
    3.0.0 bcrypt-ruby:~> 3.0,orm_adapter:~> 0.1,railties:< 5&>= 3.2.6,warden:~> 1.2.3|checksum:cccc,ruby:>= 1.9.3,created_at:2013-07-14T18:48:13Z
  DOCUMENT

  def setup
    super
    @stubbed = false
  end

  def teardown
    if @stubbed
      AgentsFyiMiner::RubyVersions.singleton_class.alias_method(:fetch, :fetch_unstubbed)
      AgentsFyiMiner::RubyVersions.singleton_class.remove_method(:fetch_unstubbed)
      @stubbed = false
    end
    super
  end

  def stub_fetch(&block)
    AgentsFyiMiner::RubyVersions.singleton_class.alias_method(:fetch_unstubbed, :fetch)
    AgentsFyiMiner::RubyVersions.define_singleton_method(:fetch, &block)
    @stubbed = true
  end

  def cache = @home + "index"

  def test_the_parser_reads_the_index_s_own_lines
    facts = INDEX.parse(DEVISE)

    assert_equal %w[0.1.0 2.2.4 3.0.0], facts.keys
    assert_equal ">= 1.9.3", facts["3.0.0"]["ruby_requirement"]
    assert_nil facts["2.2.4"]["ruby_requirement"],
      "a release that declared none is a statement, not a gap"
    assert_equal [{ "name" => "railties", "requirement" => "~> 3.1" },
                  { "name" => "warden", "requirement" => "~> 1.2.1" },
                  { "name" => "bcrypt-ruby", "requirement" => "~> 3.0" },
                  { "name" => "orm_adapter", "requirement" => "~> 0.1" }].sort_by { |dep| dep["name"] },
      facts["2.2.4"]["dependencies"].sort_by { |dep| dep["name"] }
  end

  # A requirement with several clauses joins them with `&` — which is the whole reason the
  # dependency list can be split on commas, and the form the service's own reader expects to
  # receive (it splits on `&` as well as on commas).
  def test_a_multi_clause_requirement_survives_as_one_string
    railties = INDEX.parse(DEVISE)["3.0.0"]["dependencies"].find { |dep| dep["name"] == "railties" }

    assert_equal "< 5&>= 3.2.6", railties["requirement"]
  end

  def test_a_release_with_no_dependencies_parses_to_an_empty_list
    facts = INDEX.parse("1.0.0 |checksum:aaaa,ruby:>= 2.0\n")

    assert_equal [], facts["1.0.0"]["dependencies"]
    assert_equal ">= 2.0", facts["1.0.0"]["ruby_requirement"]
  end

  def test_a_platform_suffixed_version_is_kept_as_written
    facts = INDEX.parse("1.16.0-x86_64-linux racc:~> 1.4|checksum:aa,ruby:>= 2.5\n")

    assert_equal ["1.16.0-x86_64-linux"], facts.keys
    assert_equal [{ "name" => "racc", "requirement" => "~> 1.4" }],
      facts["1.16.0-x86_64-linux"]["dependencies"]
  end

  def test_a_fresh_document_is_read_from_the_cache_without_a_request
    write("index/devise#{INDEX::CACHE_SUFFIX}", DEVISE)
    stub_fetch { |_url| raise "the cache should have been used" }

    facts = INDEX.release_facts("devise", cache: cache)

    assert_equal %w[0.1.0 2.2.4 3.0.0], facts.keys
  end

  # A stale copy is used rather than raising, the same trade the versions reader makes:
  # a miner that stopped recording facts because RubyGems was briefly down would be trading
  # a certain loss for an uncertain one.
  def test_a_stale_document_and_an_outage_fall_back_to_what_is_on_disk
    path = write("index/devise#{INDEX::CACHE_SUFFIX}", DEVISE)
    File.utime(Time.now - (INDEX::DEFAULT_MAX_AGE * 2), Time.now, path.to_s)
    stub_fetch { |_url| raise IOError, "getaddrinfo: Temporary failure in name resolution" }

    facts = INDEX.release_facts("devise", cache: cache)

    assert_equal %w[0.1.0 2.2.4 3.0.0], facts.keys
  end

  # Nothing cached and the gem is not on the index: the *caller's* answer for both that and an
  # outage is the same — leave the gem unsettled and try later — so the sentence names which
  # one it was.
  def test_a_gem_that_is_not_on_the_index_raises_with_the_code
    stub_fetch do |_url|
      raise AgentsFyiMiner::RubyVersions::IndexError.new("https://index.rubygems.org/info/nope -> 404",
        code: 404)
    end

    error = assert_raises(INDEX::NoDocument) { INDEX.release_facts("nope", cache: cache) }
    assert_includes error.message, "not on the index (404)"
  end

  def test_an_outage_with_no_cache_raises_rather_than_claiming_nothing_is_declared
    stub_fetch { |_url| raise IOError, "getaddrinfo: Temporary failure in name resolution" }

    error = assert_raises(INDEX::NoDocument) { INDEX.release_facts("devise", cache: cache) }
    assert_includes error.message, "could not be reached"
  end

  def test_a_fetched_document_is_written_to_the_cache
    stub_fetch { |_url| DEVISE }

    INDEX.release_facts("devise", cache: cache)

    assert (cache + "devise#{INDEX::CACHE_SUFFIX}").file?
    assert INDEX.document_is_cached?("devise", cache: cache)
    refute INDEX.document_is_cached?("never-fetched", cache: cache)
  end

  def test_an_empty_document_is_not_a_reading
    stub_fetch { |_url| "---\n" }

    assert_empty INDEX.release_facts("devise", cache: cache)
  end
end
