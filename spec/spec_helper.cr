require "spec"
require "file_utils"
require "../src/crystkit-http-server"

module SpecHelpers
  def self.with_temp_dir(& : String ->)
    raw = File.tempname("crystkit_http_server_spec")
    Dir.mkdir_p(raw)
    begin
      yield raw.gsub('\\', '/')
    ensure
      FileUtils.rm_rf(raw) if Dir.exists?(raw)
    end
  end

  # Returns a port the OS just handed out, reducing collisions with other
  # processes when a spec needs a concrete port number.
  def self.free_port : Int32
    server = TCPServer.new("127.0.0.1", 0)
    begin
      server.local_address.port
    ensure
      server.close
    end
  end

  # Writes a throwaway self-signed certificate/key pair into a temp directory
  # and yields their paths. The files remain present for the duration of the
  # block so specs can assert that caller-provided TLS material is not deleted.
  def self.with_self_signed_cert(& : Path, Path ->)
    with_temp_dir do |dir|
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      name = OpenSSL::X509::Name.new
      name.add_entry("CN", "localhost")
      cert.subject = name
      cert.issuer = name
      cert.not_before = OpenSSL::ASN1::Time.days_from_now(-1)
      cert.not_after = OpenSSL::ASN1::Time.days_from_now(1)
      cert.public_key = key
      cert.sign(key, OpenSSL::Digest.new("SHA256"))

      cert_path = Path[dir] / "cert.pem"
      key_path = Path[dir] / "key.pem"
      File.write(cert_path.to_s, cert.to_pem)
      File.write(key_path.to_s, key.to_pem, perm: 0o600)
      yield cert_path, key_path
    end
  end
end
