require "openssl"
require "openssl_ext/lib_crypto"
require "openssl_ext/x509"
require "openssl_ext/pkey"
require "digest/sha256"
require "base64"
require "log"

lib LibCrypto
  # Encodes an EVP_PKEY as SubjectPublicKeyInfo (the structure RFC 7469 pins).
  fun i2d_spki_pubkey = i2d_PUBKEY(pkey : EvpPKey*, out : UInt8**) : LibC::Int
end

module CrystKit::Features
  # Certificate pinning using SPKI (SubjectPublicKeyInfo) hash pins.
  #
  # Pins are base64-encoded SHA-256 hashes of a certificate's SPKI DER,
  # conventionally formatted as `"sha256/<base64hash>"`.
  #
  # Pinning complements (but does not replace) the normal TLS certificate
  # chain validation performed by the OS trust store: after the chain is
  # validated, `#verify` checks that at least one of the SPKI hashes
  # presented by the chain matches a pin configured for the host. This
  # detects man-in-the-middle attacks where an attacker has a CA-issued
  # certificate for a different identity but cannot produce the pinned
  # server's private key.
  #
  # The pinner keeps an in-memory map of host → array of pins. Hosts are
  # matched case-insensitively (normalised by `downcase`). Multiple pins
  # per host are permitted to support key rotation. Mutations and
  # verification are synchronized; `#pins_for` and `#all_pins` return
  # isolated copies.
  #
  # `#verify` raises `Core::SecurityError` on a pin mismatch (defence by
  # default) and returns `true` when no pins are configured for a host —
  # callers that prefer fail-closed behaviour must check `#pins_for`
  # explicitly before connecting.
  #
  # Usage:
  # ```
  # pinner = CertificatePinner.new
  # pinner.pin("example.com", "sha256/UFIPBLCdwpL/DP3TtuRyzMrgBmuDyS/1E7wkvrZuDB4=")
  # pinner.verify("example.com", CertificatePinner.compute_spki_hashes([cert]))
  # ```
  class CertificatePinner
    Log = ::Log.for(self)

    # Required prefix for every pin.
    PIN_PREFIX = "sha256/"

    # Number of bytes in a SHA-256 digest.
    PIN_DIGEST_SIZE = 32

    @pins : Hash(String, Array(String))
    @lock : Mutex

    # Creates an empty pinner with no pins configured.
    def initialize
      @pins = Hash(String, Array(String)).new
      @lock = Mutex.new
    end

    # Add a pin for a given host.
    #
    # *pin* must be in `"sha256/<base64>"` format, where `<base64>` decodes
    # to exactly 32 bytes (the SHA-256 digest of the certificate's raw SPKI
    # DER). Multiple pins may be added per host to support backup keys /
    # rotation; `#verify` accepts the chain if any of them match.
    #
    # Raises `Core::Error` with code `"INVALID_PIN"` when the pin does not
    # match that format.
    def pin(host : String, pin : String) : Nil
      normalized_pin = normalize_pin!(pin)
      normalized = host.downcase
      @lock.synchronize do
        (@pins[normalized] ||= [] of String) << normalized_pin
      end
    end

    # Remove all pins for a given host.
    def unpin(host : String) : Nil
      @lock.synchronize { @pins.delete(host.downcase) }
    end

    # Remove a specific pin for a host.
    #
    # The pin is canonicalized the same way as `#pin`, so callers may remove a
    # previously-added pin using the original string or its canonical form.
    # Invalid pins are ignored.
    def unpin(host : String, pin : String) : Nil
      canonical = normalize_pin!(pin) rescue nil
      return unless canonical
      normalized = host.downcase
      @lock.synchronize do
        pins = @pins[normalized]?
        pins.try(&.delete(canonical))
        @pins.delete(normalized) if pins.try(&.empty?)
      end
    end

    # Compute the SPKI pin for *cert* and add it for *host*.
    #
    # Raises `Core::Error` with code `"INVALID_CERTIFICATE"` when the
    # certificate's public key cannot be encoded.
    def pin_certificate(host : String, cert : OpenSSL::X509::Certificate) : Nil
      hash = self.class.compute_spki_hash(cert)
      unless hash
        raise Core::Error.new(
          "Could not compute an SPKI hash for the certificate",
          code: "INVALID_CERTIFICATE"
        )
      end
      pin(host, hash)
    end

    # Verify that the certificate chain for the given host matches at least
    # one configured pin.
    #
    # *spki_hashes* is the array of `"sha256/<base64>"` SPKI hashes
    # extracted from the certificates presented during the TLS handshake
    # (see `.compute_spki_hashes`).
    #
    # Returns `true` immediately when no pins are configured for *host*
    # (fail-open for unpinned hosts). When pins exist, returns `true` if
    # any presented hash matches any configured pin, otherwise raises
    # `Core::SecurityError` with code `"PINNING_FAILED"`.
    def verify(host : String, spki_hashes : Array(String)) : Bool
      normalized = host.downcase
      @lock.synchronize do
        expected = @pins[normalized]?
        return true unless expected

        return true if spki_hashes.any? { |hash| expected.includes?(hash) }

        raise Core::SecurityError.new(
          "Certificate pinning failed for #{host}: no matching SPKI hash",
          code: "PINNING_FAILED"
        )
      end
    end

    # Convenience wrapper for a single certificate. Equivalent to
    # `#verify_chain(host, [cert])`.
    def verify_certificate(host : String, cert : OpenSSL::X509::Certificate) : Bool
      verify_chain(host, [cert])
    end

    # Verify the certificate presented by an established TLS client socket.
    #
    # Returns `true` when the peer certificate matches a configured pin for
    # *host*. Raises `Core::SecurityError` with code `"PINNING_FAILED"` when
    # the socket presented no certificate or the certificate does not match.
    #
    # This verifies the peer's leaf certificate. For full-chain pinning, call
    # `#verify_chain` with the certificates obtained from your TLS stack.
    def verify_peer(host : String, socket : OpenSSL::SSL::Socket::Client) : Bool
      cert = begin
        socket.peer_certificate
      rescue
        raise Core::SecurityError.new(
          "No peer certificate presented for #{host}",
          code: "PINNING_FAILED"
        )
      end
      verify_certificate(host, cert)
    end

    # Compute SPKI hashes for *certs* and verify them against the pins for
    # *host*. Equivalent to `#verify(host, .compute_spki_hashes(certs))`.
    def verify_chain(host : String, certs : Array(OpenSSL::X509::Certificate)) : Bool
      verify(host, self.class.compute_spki_hashes(certs))
    end

    # Compute SPKI hashes from an X.509 certificate chain.
    #
    # Returns an array of `"sha256/<base64>"` pin strings, one per
    # certificate for which a SPKI hash could be derived. Certificates
    # whose public key cannot be DER-encoded are silently skipped.
    def self.compute_spki_hashes(certs : Array(OpenSSL::X509::Certificate)) : Array(String)
      certs.compact_map { |cert| compute_spki_hash(cert) }
    end

    # Compute a single SPKI hash from an X.509 certificate.
    #
    # Returns `"sha256/<base64>"` or `nil` if DER encoding fails (for
    # example when the certificate carries no extractable public key).
    # Failures are logged at warning level and do not propagate.
    def self.compute_spki_hash(cert : OpenSSL::X509::Certificate) : String?
      pkey = LibCrypto.x509_get_public_key(cert.to_unsafe)
      return nil if pkey.null?

      begin
        length = LibCrypto.i2d_spki_pubkey(pkey, Pointer(Pointer(UInt8)).null)
        return nil if length <= 0

        spki_der = Slice(UInt8).new(length)
        out = spki_der.to_unsafe
        written = LibCrypto.i2d_spki_pubkey(pkey, pointerof(out))
        return nil if written <= 0

        raw = Digest::SHA256.digest(spki_der[0, written])
        b64 = Base64.strict_encode(raw)
        "sha256/#{b64}"
      ensure
        LibCrypto.evp_pkey_free(pkey)
      end
    rescue ex
      Log.warn { "Failed to compute SPKI hash: #{ex.message}" }
      nil
    end

    # Returns a copy of the pins configured for *host* (case-insensitive), or
    # `nil` when the host has no pins. Mutating the returned array does not
    # affect the pinner.
    def pins_for(host : String) : Array(String)?
      @lock.synchronize { @pins[host.downcase]?.try(&.dup) }
    end

    # Returns a deep dup of the entire host → pins map for inspection or
    # serialisation. Mutating the returned hash or any of its arrays does not
    # affect the pinner.
    def all_pins : Hash(String, Array(String))
      @lock.synchronize { @pins.transform_values(&.dup) }
    end

    # Clear all pins. After this call `#verify` returns `true` for every
    # host.
    def clear : Nil
      @lock.synchronize { @pins.clear }
    end

    private def normalize_pin!(pin : String) : String
      stripped = pin.strip
      unless stripped.starts_with?(PIN_PREFIX)
        raise Core::Error.new(
          "Certificate pin must use the sha256/<base64> format",
          code: "INVALID_PIN"
        )
      end

      encoded = stripped[PIN_PREFIX.size..].strip
      raw = begin
        Base64.decode(encoded)
      rescue
        raise Core::Error.new(
          "Certificate pin contains invalid base64",
          code: "INVALID_PIN"
        )
      end

      unless raw.size == PIN_DIGEST_SIZE
        raise Core::Error.new(
          "Certificate pin must contain a SHA-256 digest (#{PIN_DIGEST_SIZE} bytes)",
          code: "INVALID_PIN"
        )
      end

      "#{PIN_PREFIX}#{Base64.strict_encode(raw)}"
    end
  end
end
