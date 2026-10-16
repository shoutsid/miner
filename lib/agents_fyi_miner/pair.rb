# frozen_string_literal: true

module AgentsFyiMiner
  # One upgrade to mine, and the release a caller would be moving from.
  #
  # `ecosystem` is which index the two versions are releases of, and it defaults to PyPI
  # because that is what every pair was before there was another one. It travels *on* the
  # pair rather than beside it because everything downstream keys on the pair: the ledger it
  # is recorded in, the installer that builds it, the differential that examines it, and the
  # index the release date is read from. A pair whose ecosystem had to be carried by the
  # caller is a pair that can be examined with the wrong client.
  #
  # `with` is how the one field an adapter stamps changes — see `Ecosystems`.
  Pair = Data.define(:package, :from_version, :to_version, :ecosystem) do
    def self.of(package:, from_version:, to_version:, ecosystem: "python")
      new(package: package, from_version: from_version,
        to_version: to_version, ecosystem: ecosystem)
    end

    def with_ecosystem(name) = with(ecosystem: name)

    # The spelling the ledger keys a pair under, and the one a log line names it by:
    # `httpx 0.27.0->0.28.0`.
    def to_s = "#{package} #{from_version}->#{to_version}"
  end
end
