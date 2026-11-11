require "./spec_helper"

# Certificate whose standard RFC 7469 SPKI pin is embedded below. The pin was
# produced independently with:
#
#   openssl x509 -in cert.pem -pubkey -noout \
#     | openssl pkey -pubin -outform der \
#     | openssl dgst -sha256 -binary \
#     | openssl base64 -A
PIN_TEST_CERT = <<-PEM
-----BEGIN CERTIFICATE-----
MIIDCjCCAfKgAwIBAgIJAOLGKF2c2ffSMA0GCSqGSIb3DQEBCwUAMDMxGTAXBgNV
BAMMEHBpbi10ZXN0LmV4YW1wbGUxFjAUBgNVBAoMDUNyeXN0S2l0IFRlc3QwIBcN
MjYxMTExMTI0MTI0WhgPMjEyNjEwMTgxMjQxMjRaMDMxGTAXBgNVBAMMEHBpbi10
ZXN0LmV4YW1wbGUxFjAUBgNVBAoMDUNyeXN0S2l0IFRlc3QwggEiMA0GCSqGSIb3
DQEBAQUAA4IBDwAwggEKAoIBAQDSTRzt8kdTqgWRNZonJR5YdwiwWNgwrNt5ZeaW
T5bDRlJAfJ+1dOeLg3XsHloz3d01XLMwpxwOI7cXTqfgh8me5BonNPgJhfdblhXI
7Rb9hlQLTtRcbtcbEmK+dbEKAAu1xHRJRmhRaj1VGCjRMQgyTkUMQNp9VzUGSun+
8bTZUZZvKkI6tr38OJ8MyJFVnfmHmeKjukrQXB+SXlC7SL70kpn78uy3IQPCyonR
btPpRFUQfZR6LQlT9Nsgd2FkcWBLZs67o1975mNl65VGQSElhjDrKXfskQ0wBtcl
y1/C24cuvWxvnbiibEOH3QaHj4gRtQMI6S6c3cMfd/OUNoQXAgMBAAGjHzAdMBsG
A1UdEQQUMBKCEHBpbi10ZXN0LmV4YW1wbGUwDQYJKoZIhvcNAQELBQADggEBAJC9
rAMSUMUPR2TCAyzbJohi1KuyQ4zcLXZ/ua1p3XxaHsRl1p81vP+nOpfnP+2VoruW
wowlmAqp2ogKNdVcOGfncrDeHmr0s7qU39G66iAJeam8Swxn5BbX31NZrzDqP4FJ
B6ct6ut9sOEkcFGOAf4daYclfTitNj5osdINWl22JKmJ83tRLzWT1A8zcxLj+3R5
UpD19RstUYjMPjNwpTK87LCQJR1e5QbkvHkRtnfOkXyXiS5KAJVim5H0Xbg0vZyZ
K6MpoMbphf7UpaX4qJnDTGvYEwJZRbQB00nx5pkRFBAdTDtg7tKHgKC4nkbmyvEk
Zi/9EUkpI504dYIvsC0=
-----END CERTIFICATE-----
PEM

PIN_TEST_PIN = "sha256/UFIPBLCdwpL/DP3TtuRyzMrgBmuDyS/1E7wkvrZuDB4="

EC_PIN_TEST_CERT = <<-PEM
-----BEGIN CERTIFICATE-----
MIIBhzCCAS2gAwIBAgIJAI3g5q43XEfWMAoGCCqGSM49BAMCMDYxHDAaBgNVBAMM
E2VjLXBpbi10ZXN0LmV4YW1wbGUxFjAUBgNVBAoMDUNyeXN0S2l0IFRlc3QwIBcN
MjYxMTExMTI0NTE1WhgPMjEyNjEwMTgxMjQ1MTVaMDYxHDAaBgNVBAMME2VjLXBp
bi10ZXN0LmV4YW1wbGUxFjAUBgNVBAoMDUNyeXN0S2l0IFRlc3QwWTATBgcqhkjO
PQIBBggqhkjOPQMBBwNCAATBw/wK8zs49UGmbplsNWvoTPQthsDn0yVHPcKADdU+
M586XqmYdZU02wyBm9eZ2Hj2kIQ82YPH159buV9pX/4KoyIwIDAeBgNVHREEFzAV
ghNlYy1waW4tdGVzdC5leGFtcGxlMAoGCCqGSM49BAMCA0gAMEUCIQDPomGPko+0
Kntxpos5jG/nPu6fflxzvr2hSmrRTJDVrAIgLvlQq8s9ZQmiXC8vSJRwn14GRrWw
RKeWQ4qE1yCX96U=
-----END CERTIFICATE-----
PEM

EC_PIN_TEST_PIN = "sha256/ZVXTMlWSFUzwKvJypUNgljONOBU5Dnk/rMgkBdZb904="

private def pin_test_cert : OpenSSL::X509::Certificate
  OpenSSL::X509::Certificate.new(PIN_TEST_CERT)
end

describe CrystKit::Features::CertificatePinner do
  it "computes the standard RFC 7469 SHA-256 SPKI pin" do
    CrystKit::Features::CertificatePinner.compute_spki_hash(pin_test_cert).should eq(PIN_TEST_PIN)
  end

  it "computes SPKI pins for EC keys" do
    cert = OpenSSL::X509::Certificate.new(EC_PIN_TEST_CERT)
    CrystKit::Features::CertificatePinner.compute_spki_hash(cert).should eq(EC_PIN_TEST_PIN)
  end

  it "computes one pin per certificate in a chain" do
    cert = pin_test_cert
    hashes = CrystKit::Features::CertificatePinner.compute_spki_hashes([cert, cert])
    hashes.should eq([PIN_TEST_PIN, PIN_TEST_PIN])
  end

  it "verifies a matching pin" do
    pinner = CrystKit::Features::CertificatePinner.new
    pinner.pin("pin-test.example", PIN_TEST_PIN)
    pinner.verify("pin-test.example", [PIN_TEST_PIN]).should be_true
  end

  it "matches hosts case-insensitively" do
    pinner = CrystKit::Features::CertificatePinner.new
    pinner.pin("PIN-TEST.EXAMPLE", PIN_TEST_PIN)
    pinner.verify("pin-test.example", [PIN_TEST_PIN]).should be_true
  end

  it "raises PINNING_FAILED when no presented hash matches" do
    pinner = CrystKit::Features::CertificatePinner.new
    pinner.pin("pin-test.example", PIN_TEST_PIN)

    error = expect_raises(CrystKit::Core::SecurityError) do
      pinner.verify("pin-test.example", ["sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="])
    end
    error.code.should eq("PINNING_FAILED")
  end

  it "passes unpinned hosts through unchanged" do
    pinner = CrystKit::Features::CertificatePinner.new
    pinner.verify("unpinned.example", [] of String).should be_true
  end

  it "accepts any configured pin during key rotation" do
    pinner = CrystKit::Features::CertificatePinner.new
    backup = "sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    pinner.pin("pin-test.example", backup)
    pinner.pin("pin-test.example", PIN_TEST_PIN)

    pinner.verify("pin-test.example", [PIN_TEST_PIN]).should be_true
    pinner.verify("pin-test.example", [backup]).should be_true
  end

  it "removes one pin without dropping the others" do
    pinner = CrystKit::Features::CertificatePinner.new
    backup = "sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    pinner.pin("pin-test.example", PIN_TEST_PIN)
    pinner.pin("pin-test.example", backup)

    pinner.unpin("pin-test.example", PIN_TEST_PIN)
    pinner.pins_for("pin-test.example").should eq([backup])
    pinner.unpin("pin-test.example", backup)
    pinner.pins_for("pin-test.example").should be_nil
  end

  it "removes every pin for a host" do
    pinner = CrystKit::Features::CertificatePinner.new
    pinner.pin("pin-test.example", PIN_TEST_PIN)
    pinner.pin("pin-test.example", "sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
    pinner.pin("other.example", PIN_TEST_PIN)

    pinner.unpin("PIN-TEST.EXAMPLE")
    pinner.pins_for("pin-test.example").should be_nil
    pinner.pins_for("other.example").should eq([PIN_TEST_PIN])
  end

  it "clears every pin" do
    pinner = CrystKit::Features::CertificatePinner.new
    pinner.pin("a.example", PIN_TEST_PIN)
    pinner.pin("b.example", PIN_TEST_PIN)

    pinner.clear
    pinner.pins_for("a.example").should be_nil
    pinner.pins_for("b.example").should be_nil
  end

  it "returns an isolated copy from pins_for" do
    pinner = CrystKit::Features::CertificatePinner.new
    pinner.pin("pin-test.example", PIN_TEST_PIN)

    copy = pinner.pins_for("pin-test.example").not_nil!
    copy << "sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    pinner.pins_for("pin-test.example").should eq([PIN_TEST_PIN])
  end

  it "returns an isolated copy from all_pins" do
    pinner = CrystKit::Features::CertificatePinner.new
    pinner.pin("pin-test.example", PIN_TEST_PIN)

    copy = pinner.all_pins
    copy["pin-test.example"] << "sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    copy.delete("pin-test.example")

    pinner.pins_for("pin-test.example").should eq([PIN_TEST_PIN])
  end

  it "returns nil when a certificate has no public key" do
    cert = OpenSSL::X509::Certificate.new
    CrystKit::Features::CertificatePinner.compute_spki_hash(cert).should be_nil
    CrystKit::Features::CertificatePinner.compute_spki_hashes([cert]).should be_empty
  end

  it "rejects pinning a certificate without a public key" do
    pinner = CrystKit::Features::CertificatePinner.new
    error = expect_raises(CrystKit::Core::Error) do
      pinner.pin_certificate("pin-test.example", OpenSSL::X509::Certificate.new)
    end
    error.code.should eq("INVALID_CERTIFICATE")
  end

  it "pins a certificate directly" do
    pinner = CrystKit::Features::CertificatePinner.new
    pinner.pin_certificate("pin-test.example", pin_test_cert)
    pinner.pins_for("pin-test.example").should eq([PIN_TEST_PIN])
  end

  it "verifies a certificate directly" do
    pinner = CrystKit::Features::CertificatePinner.new
    pinner.pin("pin-test.example", PIN_TEST_PIN)
    pinner.verify_certificate("pin-test.example", pin_test_cert).should be_true
  end

  it "verifies a certificate chain" do
    pinner = CrystKit::Features::CertificatePinner.new
    pinner.pin("pin-test.example", PIN_TEST_PIN)
    pinner.verify_chain("pin-test.example", [pin_test_cert, pin_test_cert]).should be_true
  end

  it "unpins using a whitespace-normalized pin" do
    pinner = CrystKit::Features::CertificatePinner.new
    pinner.pin("pin-test.example", PIN_TEST_PIN)
    pinner.unpin("pin-test.example", "  #{PIN_TEST_PIN}\n")
    pinner.pins_for("pin-test.example").should be_nil
  end

  it "normalizes whitespace around a pin" do
    pinner = CrystKit::Features::CertificatePinner.new
    pinner.pin("pin-test.example", "  #{PIN_TEST_PIN}\n")
    pinner.pins_for("pin-test.example").should eq([PIN_TEST_PIN])
    pinner.verify("pin-test.example", [PIN_TEST_PIN]).should be_true
  end

  it "rejects pins that are not SHA-256 base64 SPKI hashes" do
    pinner = CrystKit::Features::CertificatePinner.new

    expect_raises(CrystKit::Core::Error, /sha256/i) do
      pinner.pin("pin-test.example", "sha1/abc")
    end
    expect_raises(CrystKit::Core::Error, /base64/i) do
      pinner.pin("pin-test.example", "sha256/not-base64!")
    end
    expect_raises(CrystKit::Core::Error, /SHA-256/i) do
      pinner.pin("pin-test.example", "sha256/#{Base64.strict_encode(Bytes.new(31))}")
    end
  end
end

describe "TLS peer verification" do
  it "verifies the certificate presented during a real TLS handshake" do
    server = CrystKit::Features::LocalhostServer.new
    port = server.start(CrystKit::Features::ServerOptions.new(tls_enabled: true))
    socket = nil
    begin
      tcp = TCPSocket.new("127.0.0.1", port)
      socket = OpenSSL::SSL::Socket::Client.new(
        tcp,
        context: OpenSSL::SSL::Context::Client.insecure,
        hostname: "localhost"
      )
      cert = socket.peer_certificate

      pinner = CrystKit::Features::CertificatePinner.new
      pinner.pin_certificate("localhost", cert)
      pinner.verify_peer("localhost", socket).should be_true
    ensure
      socket.try(&.close)
      server.stop
    end
  end

  it "raises PINNING_FAILED when the peer certificate does not match" do
    server = CrystKit::Features::LocalhostServer.new
    port = server.start(CrystKit::Features::ServerOptions.new(tls_enabled: true))
    socket = nil
    begin
      tcp = TCPSocket.new("127.0.0.1", port)
      socket = OpenSSL::SSL::Socket::Client.new(
        tcp,
        context: OpenSSL::SSL::Context::Client.insecure,
        hostname: "localhost"
      )

      pinner = CrystKit::Features::CertificatePinner.new
      pinner.pin_certificate("localhost", pin_test_cert)
      error = expect_raises(CrystKit::Core::SecurityError) do
        pinner.verify_peer("localhost", socket)
      end
      error.code.should eq("PINNING_FAILED")
    ensure
      socket.try(&.close)
      server.stop
    end
  end
end
