# frozen_string_literal: true

require "digest"
require "json"
require "openssl"
require "webrick"
require "webrick/https"

class Task3LoopbackMutualTlsRpcServer
  attr_reader :client_certificate, :client_key, :endpoint_sha256,
              :client_certificate_sha256, :endpoint_uri, :calls

  def initialize(network_id: "candidate-task3", close_after_identity: false, &handler)
    @network_id = network_id
    @close_after_identity = close_after_identity
    @handler = handler || ->(_method, _params) { raise "unexpected RPC method" }
    @calls = []
    build_certificates
    store = OpenSSL::X509::Store.new
    store.add_cert(@ca_certificate)
    @server = WEBrick::HTTPServer.new(
      BindAddress: "127.0.0.1", Port: 0,
      Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL), AccessLog: [],
      SSLEnable: true, SSLCertificate: @server_certificate, SSLPrivateKey: @server_key,
      SSLClientCA: [@ca_certificate], SSLCertificateStore: store,
      SSLVerifyClient: OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
    )
    @server.mount_proc("/") { |request, response| serve(request, response) }
    port = @server.listeners.fetch(0).addr.fetch(1)
    @endpoint_uri = "https://127.0.0.1:#{port}/".freeze
    @thread = Thread.new { @server.start }
  end

  def connection_options
    {
      endpoint_uri: @endpoint_uri,
      endpoint_sha256: @endpoint_sha256,
      client_certificate_sha256: @client_certificate_sha256,
      network_id: @network_id,
      client_certificate: @client_certificate,
      client_key: @client_key,
      ca_certificate: @ca_certificate
    }
  end

  def stop
    @server.shutdown
    @thread.join(2)
  end

  private

  def serve(request, response)
    payload = JSON.parse(request.body)
    method = payload.fetch("method")
    params = payload.fetch("params")
    @calls << { "method" => method, "params" => params }
    result = if method == "private_network_identity"
               {
                 "network_id" => @network_id,
                 "client_certificate_sha256" => Digest::SHA256.hexdigest(request.client_cert.to_der)
               }
             else
               @handler.call(method, params)
             end
    response.status = 200
    response["Content-Type"] = "application/json"
    response["Connection"] = method == "private_network_identity" && @close_after_identity ? "close" : "keep-alive"
    response.body = JSON.generate("result" => result)
  rescue StandardError => error
    response.status = 200
    response["Content-Type"] = "application/json"
    response.body = JSON.generate("error" => error.message)
  end

  def build_certificates
    @ca_key = OpenSSL::PKey::RSA.new(2048)
    @ca_certificate = certificate(
      common_name: "task3-test-ca", key: @ca_key, serial: 1, issuer_certificate: nil,
      issuer_key: @ca_key, extensions: [["basicConstraints", "CA:TRUE", true], ["keyUsage", "keyCertSign,cRLSign", true]]
    )
    @server_key = OpenSSL::PKey::RSA.new(2048)
    @server_certificate = certificate(
      common_name: "127.0.0.1", key: @server_key, serial: 2,
      issuer_certificate: @ca_certificate, issuer_key: @ca_key,
      extensions: [["basicConstraints", "CA:FALSE", true], ["keyUsage", "digitalSignature,keyEncipherment", true],
                   ["extendedKeyUsage", "serverAuth", false], ["subjectAltName", "IP:127.0.0.1", false]]
    )
    @client_key = OpenSSL::PKey::RSA.new(2048)
    @client_certificate = certificate(
      common_name: "task3-client", key: @client_key, serial: 3,
      issuer_certificate: @ca_certificate, issuer_key: @ca_key,
      extensions: [["basicConstraints", "CA:FALSE", true], ["keyUsage", "digitalSignature", true],
                   ["extendedKeyUsage", "clientAuth", false]]
    )
    @endpoint_sha256 = Digest::SHA256.hexdigest(@server_certificate.to_der).freeze
    @client_certificate_sha256 = Digest::SHA256.hexdigest(@client_certificate.to_der).freeze
  end

  def certificate(common_name:, key:, serial:, issuer_certificate:, issuer_key:, extensions:)
    value = OpenSSL::X509::Certificate.new
    value.version = 2
    value.serial = serial
    value.subject = OpenSSL::X509::Name.parse("/CN=#{common_name}")
    value.issuer = issuer_certificate ? issuer_certificate.subject : value.subject
    value.public_key = key.public_key
    value.not_before = Time.now - 60
    value.not_after = Time.now + 3600
    factory = OpenSSL::X509::ExtensionFactory.new
    factory.subject_certificate = value
    factory.issuer_certificate = issuer_certificate || value
    extensions.each { |name, data, critical| value.add_extension(factory.create_extension(name, data, critical)) }
    value.sign(issuer_key, OpenSSL::Digest::SHA256.new)
    value
  end
end
