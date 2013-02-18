# -*- coding: binary -*-
require 'rex/socket'
require 'rex/proto/http'
require 'rex/text'
require 'digest'
require 'rex/proto/ntlm/crypt'
require 'rex/proto/ntlm/constants'
require 'rex/proto/ntlm/utils'
require 'rex/proto/ntlm/exceptions'

require 'pry'

module Rex
module Proto
module Http

###
#
# Acts as a client to an HTTP server, sending requests and receiving responses.
#
# See the RFC: http://www.w3.org/Protocols/rfc2616/rfc2616.html
#
###
class Client

	DefaultUserAgent = "Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1)"

	#
	# Creates a new client instance
	#
	def initialize(host, port = 80, context = {}, ssl = nil, ssl_version = nil, proxies = nil, username = '', password = '')
		self.hostname = host
		self.port     = port.to_i
		self.context  = context
		self.ssl      = ssl
		self.ssl_version = ssl_version
		self.proxies  = proxies
		self.username = username
		self.password = password
		self.config = {
			'read_max_data'   => (1024*1024*1),
			'vhost'           => self.hostname,
			'version'         => '1.1',
			'agent'           => DefaultUserAgent,
			#
			# Evasion options
			#
			'uri_encode_mode'        => 'hex-normal', # hex-all, hex-random, u-normal, u-random, u-all
			'uri_encode_count'       => 1,       # integer
			'uri_full_url'           => false,   # bool
			'pad_method_uri_count'   => 1,       # integer
			'pad_uri_version_count'  => 1,       # integer
			'pad_method_uri_type'    => 'space', # space, tab, apache
			'pad_uri_version_type'   => 'space', # space, tab, apache
			'method_random_valid'    => false,   # bool
			'method_random_invalid'  => false,   # bool
			'method_random_case'     => false,   # bool
			'version_random_valid'   => false,   # bool
			'version_random_invalid' => false,   # bool
			'version_random_case'    => false,   # bool
			'uri_dir_self_reference' => false,   # bool
			'uri_dir_fake_relative'  => false,   # bool
			'uri_use_backslashes'    => false,   # bool
			'pad_fake_headers'       => false,   # bool
			'pad_fake_headers_count' => 16,      # integer
			'pad_get_params'         => false,   # bool
			'pad_get_params_count'   => 8,       # integer
			'pad_post_params'        => false,   # bool
			'pad_post_params_count'  => 8,       # integer
			'uri_fake_end'           => false,   # bool
			'uri_fake_params_start'  => false,   # bool
			'header_folding'         => false,   # bool
			'chunked_size'           => 0,        # integer
			#
			# NTLM Options
			#
			'usentlm2_session' => true,
			'use_ntlmv2'       => true,
			'send_lm'         => true,
			'send_ntlm'       => true,
			'SendSPN'  => true,
			'UseLMKey' => false,
			'domain' => 'WORKSTATION',
			#
			# Digest Options
			#
			'DigestAuthIIS' => true
		}

		# This is not used right now...
		self.config_types = {
			'uri_encode_mode'        => ['hex-normal', 'hex-all', 'hex-random', 'u-normal', 'u-random', 'u-all'],
			'uri_encode_count'       => 'integer',
			'uri_full_url'           => 'bool',
			'pad_method_uri_count'   => 'integer',
			'pad_uri_version_count'  => 'integer',
			'pad_method_uri_type'    => ['space', 'tab', 'apache'],
			'pad_uri_version_type'   => ['space', 'tab', 'apache'],
			'method_random_valid'    => 'bool',
			'method_random_invalid'  => 'bool',
			'method_random_case'     => 'bool',
			'version_random_valid'   => 'bool',
			'version_random_invalid' => 'bool',
			'version_random_case'    => 'bool',
			'uri_dir_self_reference' => 'bool',
			'uri_dir_fake_relative'  => 'bool',
			'uri_use_backslashes'    => 'bool',
			'pad_fake_headers'       => 'bool',
			'pad_fake_headers_count' => 'integer',
			'pad_get_params'         => 'bool',
			'pad_get_params_count'   => 'integer',
			'pad_post_params'        => 'bool',
			'pad_post_params_count'  => 'integer',
			'uri_fake_end'           => 'bool',
			'uri_fake_params_start'  => 'bool',
			'header_folding'         => 'bool',
			'chunked_size'           => 'integer'
		}
	end

	#
	# Set configuration options
	#
	def set_config(opts = {})
		opts.each_pair do |var,val|
			# Default type is string
			typ = self.config_types[var] || 'string'

			# These are enum types
			if(typ.class.to_s == 'Array')
				if not typ.include?(val)
					raise RuntimeError, "The specified value for #{var} is not one of the valid choices"
				end
			end

			# The caller should have converted these to proper ruby types, but
			# take care of the case where they didn't before setting the
			# config.

			if(typ == 'bool')
				val = (val =~ /^(t|y|1)$/i ? true : false || val === true)
			end

			if(typ == 'integer')
				val = val.to_i
			end

			self.config[var]=val
		end

	end

	#
	# Create an arbitrary HTTP request
	#
	# @param opts [Hash]
	# @option opts 'agent'         [String] User-Agent header value
	# @option opts 'basic_auth'    [String] Basic-Auth header value
	# @option opts 'connection'    [String] Connection header value
	# @option opts 'cookie'        [String] Cookie header value
	# @option opts 'data'          [String] HTTP data (only useful with some methods, see rfc2616)
	# @option opts 'encode'        [Bool]   URI encode the supplied URI, default: false
	# @option opts 'headers'       [Hash]   HTTP headers, e.g. <code>{ "X-MyHeader" => "value" }</code>
	# @option opts 'method'        [String] HTTP method to use in the request, not limited to standard methods defined by rfc2616, default: GET
	# @option opts 'proto'         [String] protocol, default: HTTP
	# @option opts 'query'         [String] raw query string
	# @option opts 'raw_headers'   [Hash]   HTTP headers
	# @option opts 'uri'           [String] the URI to request
	# @option opts 'version'       [String] version of the protocol, default: 1.1
	# @option opts 'vhost'         [String] Host header value
	#
	# @return [Request]
	def request_raw(opts={})
		c_ag   = opts['agent']      || config['agent']
		c_auth = opts['basic_auth'] || config['basic_auth'] || ''
		c_body = opts['data']       || ''
		c_conn = opts['connection']
		c_cook = opts['cookie']     || config['cookie']
		c_enc  = opts['encode']     || false
		c_head = opts['headers']    || config['headers'] || {}
		c_host = opts['vhost']      || config['vhost'] || self.hostname
		c_meth = opts['method']     || 'GET'
		c_prot = opts['proto']      || 'HTTP'
		c_qs   = opts['query']
		c_rawh = opts['raw_headers']|| config['raw_headers'] || ''
		c_uri  = opts['uri']        || '/'
		c_vers = opts['version']    || config['version'] || '1.1'

		# An agent parameter was specified, but so was a header, prefer the header
		if c_ag and c_head.keys.map{|x| x.downcase }.include?('user-agent')
			c_ag = nil
		end

		uri    = set_uri(c_uri)

		req = ''
		req << set_method(c_meth)
		req << set_method_uri_spacer()
		req << set_uri_prepend()
		req << (c_enc ? set_encode_uri(uri) : uri)

		if (c_qs)
			req << '?'
			req << (c_enc ? set_encode_qs(c_qs) : c_qs)
		end

		req << set_uri_append()
		req << set_uri_version_spacer()
		req << set_version(c_prot, c_vers)
		req << set_host_header(c_host)
		req << set_agent_header(c_ag)

		if (c_auth.length > 0)
			unless c_head['Authorization'] and c_head['Authorization'].include? "Basic"
				req << set_basic_auth_header(c_auth)
			end
		end

		req << set_cookie_header(c_cook)
		req << set_connection_header(c_conn)
		req << set_extra_headers(c_head)
		req << set_raw_headers(c_rawh)
		req << set_body(c_body)

		request = Request.new
		request.parse(req)
		request.options = opts

		request
	end


	#
	# Create a CGI compatible request
	#
	# @param (see #request_raw)
	# @option opts (see #request_raw)
	# @option opts 'ctype'         [String] Content-Type header value, default: +application/x-www-form-urlencoded+
	# @option opts 'encode_params' [Bool]   URI encode the GET or POST variables (names and values), default: true
	# @option opts 'vars_get'      [Hash]   GET variables as a hash to be translated into a query string
	# @option opts 'vars_post'     [Hash]   POST variables as a hash to be translated into POST data
	#
	# @return [Request]
	def request_cgi(opts={})
		opts['agent']             ||= config['agent']
		opts['basic_auth']     = opts['basic_auth'] || config['basic_auth'] || ''
		opts['data']                ||= ''
		opts['uri']                   ||= '/'
		opts['cookie']            ||= config['cookie']
		opts['encode']           ||= false
		opts['headers']          ||= config['headers'] || {}
		opts['vhost']              ||= config['vhost']
		opts['method']          ||= 'GET'
		opts['proto']              ||= 'HTTP'
		opts['query']              ||= ''
		opts['raw_headers']  = opts['raw_headers'] || config['raw_headers'] || ''
		opts['ctype']               ||= 'application/x-www-form-urlencoded'
		opts['vars_get']          ||= {}
		opts['vars_post']        ||= {}
		opts['version']            = opts['version']     || config['version'] || '1.1'	
		opts['cgi']                   =  true
		opts['port']                = self.port

		if opts['encode_params'] == true or opts['encode_params'].nil?
			opts['encode_params'] = true
		else
			opts['encode_params'] = false
		end

		req = ClientRequest.new(opts,self.config)
	end

	#
	# Connects to the remote server if possible.
	#
	# @param t [Fixnum] Timeout
	# @see Rex::Socket::Tcp.create
	# @return [Rex::Socket::Tcp]
	def connect(t = -1)
		# If we already have a connection and we aren't pipelining, close it.
		if (self.conn)
			if !pipelining?
				close
			else
				return self.conn
			end
		end

		timeout = (t.nil? or t == -1) ? 0 : t

		self.conn = Rex::Socket::Tcp.create(
			'PeerHost'  => self.hostname,
			'PeerPort'  => self.port.to_i,
			'LocalHost' => self.local_host,
			'LocalPort' => self.local_port,
			'Context'   => self.context,
			'SSL'       => self.ssl,
			'SSLVersion'=> self.ssl_version,
			'Proxies'   => self.proxies,
			'Timeout'   => timeout
		)
	end

	#
	# Closes the connection to the remote server.
	#
	def close
		if (self.conn)
			self.conn.shutdown
			self.conn.close
		end

		self.conn = nil
	end

	#
	# Sends a request and gets a response back
	#
	# If the request is a 401, and we have creds, it will attempt to complete
	# authentication and return the final response
	#
	def send_recv(req, t = -1, persist=false)
		res = _send_recv(req,t,persist)
		if res and res.code == 401 and res.headers['WWW-Authenticate'] and have_creds?
			res = send_auth(res, req.options, t, persist)
		end
		res
	end

	#
	# Transmit an HTTP request and receive the response
	#
	# If persist is set, then the request will attempt to reuse an existing
	# connection.
	#
	# Call this directly instead of {#send_recv} if you don't want automatic
	# authentication handling.
	#
	# @return [Response]
	def _send_recv(req, t = -1, persist=false)
		@pipeline = persist
		send_request(req, t)
		res = read_response(t)
		res.request = req.to_s if res
		res
	end

	#
	# Send an HTTP request to the server
	#
	# @param req [Request,#to_s] The request to send
	# @param t (see #connect)
	def send_request(req, t = -1)
		connect(t)
		conn.put(req.to_s)
	end

	# Validates that the client has creds
	def have_creds?
		!(self.username.nil?) && self.username != ''
	end

	#
	# Params -
	#    res = The 401 response we need to auth from
	#    opts = the opts used to generate the request that created this response
	#    t = the timeout for the http requests
	#    persist = whether to persist the tcp connection for HTTP Pipelining
	#
	#  Parses the response for what Authentication methods are supported.
	#  Sets the corect authorization options and passes them on to the correct
	#  method for sending the next request.
	def send_auth(res, opts, t, persist)
		supported_auths = res.headers['WWW-Authenticate']
		if supported_auths.include? 'Basic'
			if opts['headers']
				opts['headers']['Authorization'] = basic_auth_header(self.username,self.password)
			else
				opts['headers'] = { 'Authorization' => basic_auth_header(self.username,self.password)}
			end

			req = request_cgi(opts)
			res = _send_recv(req,t,persist)
			return res
		elsif  supported_auths.include? "Digest"
			opts['DigestAuthUser'] = self.username.to_s
			opts['DigestAuthPassword'] = self.password.to_s
			temp_response = digest_auth(opts)
			if temp_response.kind_of? Rex::Proto::Http::Response
				res = temp_response
			end
			return res
		elsif supported_auths.include? "NTLM"
			opts['provider'] = 'NTLM'
			temp_response = negotiate_auth(opts)
			if temp_response.kind_of? Rex::Proto::Http::Response
				res = temp_response
			end
			return res
		elsif supported_auths.include? "Negotiate"
			opts['provider'] = 'Negotiate'
			temp_response = negotiate_auth(opts)
			if temp_response.kind_of? Rex::Proto::Http::Response
				res = temp_response
			end
			return res
		end
		return res
	end

	# Converts username and password into the HTTP Basic
	# authorization string.
	def basic_auth_header(username,password)
		auth_str = username.to_s + ":" + password.to_s
		auth_str = "Basic " + Rex::Text.encode_base64(auth_str)
	end


	#
	# Opts -
	#   Inherits all the same options as send_request_cgi
	#   Also expects some specific opts
	#   DigestAuthUser - The username for DigestAuth
	#   DigestAuthPass - The password for DigestAuth
	#   DigestAuthIIS - IIS uses a slighlty different implementation, set this for IIS support
	#
	# This method builds new request to complete a Digest Authentication cycle.
	# We do not persist the original connection , to clear state in preparation for our auth
	# We do persist the rest of the connection stream because Digest is a tcp session
	# based authentication method.
	#

	def digest_auth(opts={})
		@nonce_count = 0

		to = opts['timeout'] || 20

		digest_user = opts['DigestAuthUser'] || ""
		digest_password =  opts['DigestAuthPassword'] || ""

		method = opts['method']
		path = opts['uri']
		iis = true
		if (opts['DigestAuthIIS'] == false or self.config['DigestAuthIIS'] == false)
			iis = false
		end

		begin
		@nonce_count += 1

		resp = opts['response']

		if not resp
			# Get authentication-challenge from server, and read out parameters required
			r = request_cgi(opts.merge({
					'uri' => path,
					'method' => method }))
			resp = _send_recv(r, to)
			unless resp.kind_of? Rex::Proto::Http::Response
				return nil
			end

			if resp.code != 401
				return resp
			end
			return resp unless resp.headers['WWW-Authenticate']
		end

		# Don't anchor this regex to the beginning of string because header
		# folding makes it appear later when the server presents multiple
		# WWW-Authentication options (such as is the case with IIS configured
		# for Digest or NTLM).
		resp['www-authenticate'] =~ /Digest (.*)/

		parameters = {}
		$1.split(/,[[:space:]]*/).each do |p|
			k, v = p.split("=", 2)
			parameters[k] = v.gsub('"', '')
		end

		qop = parameters['qop']

		if parameters['algorithm'] =~ /(.*?)(-sess)?$/
			algorithm = case $1
			when 'MD5' then Digest::MD5
			when 'SHA1' then Digest::SHA1
			when 'SHA2' then Digest::SHA2
			when 'SHA256' then Digest::SHA256
			when 'SHA384' then Digest::SHA384
			when 'SHA512' then Digest::SHA512
			when 'RMD160' then Digest::RMD160
			else raise Error, "unknown algorithm \"#{$1}\""
			end
			algstr = parameters["algorithm"]
			sess = $2
		else
			algorithm = Digest::MD5
			algstr = "MD5"
			sess = false
		end

		a1 = if sess then
			[
				algorithm.hexdigest("#{digest_user}:#{parameters['realm']}:#{digest_password}"),
				parameters['nonce'],
				@cnonce
			].join ':'
		else
			"#{digest_user}:#{parameters['realm']}:#{digest_password}"
		end

		ha1 = algorithm.hexdigest(a1)
		ha2 = algorithm.hexdigest("#{method}:#{path}")

		request_digest = [ha1, parameters['nonce']]
		request_digest.push(('%08x' % @nonce_count), @cnonce, qop) if qop
		request_digest << ha2
		request_digest = request_digest.join ':'

		# Same order as IE7
		auth = [
			"Digest username=\"#{digest_user}\"",
			"realm=\"#{parameters['realm']}\"",
			"nonce=\"#{parameters['nonce']}\"",
			"uri=\"#{path}\"",
			"cnonce=\"#{@cnonce}\"",
			"nc=#{'%08x' % @nonce_count}",
			"algorithm=#{algstr}",
			"response=\"#{algorithm.hexdigest(request_digest)[0, 32]}\"",
			# The spec says the qop value shouldn't be enclosed in quotes, but
			# some versions of IIS require it and Apache accepts it.  Chrome
			# and Firefox both send it without quotes but IE does it this way.
			# Use the non-compliant-but-everybody-does-it to be as compatible
			# as possible by default.  The user can override if they don't like
			# it.
			if qop.nil? then
			elsif iis then
				"qop=\"#{qop}\""
			else
				"qop=#{qop}"
			end,
			if parameters.key? 'opaque' then
				"opaque=\"#{parameters['opaque']}\""
			end
		].compact

		headers ={ 'Authorization' => auth.join(', ') }
		headers.merge!(opts['headers']) if opts['headers']

		# Send main request with authentication
		r = request_cgi(opts.merge({
			'uri' => path,
			'method' => method,
			'headers' => headers }))
		resp = _send_recv(r, to, true)
		unless resp.kind_of? Rex::Proto::Http::Response
			return nil
		end

		return resp

		rescue ::Errno::EPIPE, ::Timeout::Error
		end
	end

	#
	# Opts -
	#   Inherits all the same options as send_request_cgi
	#   provider - What Negotiate Provider to use (supports NTLM and Negotiate)
	#
	# Builds a series of requests to complete Negotiate Auth. Works essentially
	# the same way as Digest auth. Same pipelining concerns exist.
	#

	def negotiate_auth(opts={})
		ntlm_options = {
			:signing          => false,
			:usentlm2_session => self.config['usentlm2_session'],
			:use_ntlmv2       => self.config['use_ntlmv2'],
			:send_lm          => self.config['send_lm'],
			:send_ntlm        => self.config['send_ntlm']
		}

		to = opts['timeout'] || 20
		opts['username'] ||= self.username.to_s
		opts['password'] ||= self.password.to_s

		if opts['provider'] and opts['provider'].include? 'Negotiate'
			provider = "Negotiate "
		else
			provider = 'NTLM '
		end

		opts['method']||= 'GET'
		opts['headers']||= {}

		ntlmssp_flags = ::Rex::Proto::NTLM::Utils.make_ntlm_flags(ntlm_options)
		workstation_name = Rex::Text.rand_text_alpha(rand(8)+1)
		domain_name = self.config['domain']

		b64_blob = Rex::Text::encode_base64(
			::Rex::Proto::NTLM::Utils::make_ntlmssp_blob_init(
				domain_name,
				workstation_name,
				ntlmssp_flags
		))

		ntlm_message_1 = provider + b64_blob

		begin
			# First request to get the challenge
			opts['headers']['Authorization'] = ntlm_message_1
			r = request_cgi(opts)
			resp = _send_recv(r, to)
			unless resp.kind_of? Rex::Proto::Http::Response
				return nil
			end

			return resp unless resp.code == 401 && resp.headers['WWW-Authenticate']

			# Get the challenge and craft the response
			ntlm_challenge = resp.headers['WWW-Authenticate'].scan(/#{provider}([A-Z0-9\x2b\x2f=]+)/i).flatten[0]
			return resp unless ntlm_challenge

			ntlm_message_2 = Rex::Text::decode_base64(ntlm_challenge)
			blob_data = ::Rex::Proto::NTLM::Utils.parse_ntlm_type_2_blob(ntlm_message_2)

			challenge_key        = blob_data[:challenge_key]
			server_ntlmssp_flags = blob_data[:server_ntlmssp_flags]       #else should raise an error
			default_name         = blob_data[:default_name]         || '' #netbios name
			default_domain       = blob_data[:default_domain]       || '' #netbios domain
			dns_host_name        = blob_data[:dns_host_name]        || '' #dns name
			dns_domain_name      = blob_data[:dns_domain_name]      || '' #dns domain
			chall_MsvAvTimestamp = blob_data[:chall_MsvAvTimestamp] || '' #Client time

			spnopt = {:use_spn => self.config['SendSPN'], :name =>  self.hostname}

			resp_lm, resp_ntlm, client_challenge, ntlm_cli_challenge = ::Rex::Proto::NTLM::Utils.create_lm_ntlm_responses(
				opts['username'],
				opts['password'],
				challenge_key,
				domain_name,
				default_name,
				default_domain,
				dns_host_name,
				dns_domain_name,
				chall_MsvAvTimestamp,
				spnopt,
				ntlm_options
			)

			ntlm_message_3 = ::Rex::Proto::NTLM::Utils.make_ntlmssp_blob_auth(
				domain_name,
				workstation_name,
				opts['username'],
				resp_lm,
				resp_ntlm,
				'',
				ntlmssp_flags
			)

			ntlm_message_3 = Rex::Text::encode_base64(ntlm_message_3)

			# Send the response
			opts['headers']['Authorization'] = "#{provider}#{ntlm_message_3}"
			r = request_cgi(opts)
			resp = _send_recv(r, to, true)
			unless resp.kind_of? Rex::Proto::Http::Response
				return nil
			end
			return resp

		rescue ::Errno::EPIPE, ::Timeout::Error
			return nil
		end
	end
	#
	# Read a response from the server
	#
	def read_response(t = -1, opts = {})

		resp = Response.new
		resp.max_data = config['read_max_data']

		# Wait at most t seconds for the full response to be read in.  We only
		# do this if t was specified as a negative value indicating an infinite
		# wait cycle.  If t were specified as nil it would indicate that no
		# response parsing is required.

		return resp if not t

		Timeout.timeout((t < 0) ? nil : t) do

			rv = nil
			while (
			         rv != Packet::ParseCode::Completed and
			         rv != Packet::ParseCode::Error
		          )

				begin

					buff = conn.get_once(-1, 1)
					rv   = resp.parse( buff || '' )

				##########################################################################
				# XXX: NOTE: BUG: get_once currently (as of r10042) rescues "Exception"
				# As such, the following rescue block will never be reached.  -jjd
				##########################################################################

				# Handle unexpected disconnects
				rescue ::Errno::EPIPE, ::EOFError, ::IOError
					case resp.state
					when Packet::ParseState::ProcessingHeader
						resp = nil
					when Packet::ParseState::ProcessingBody
						# truncated request, good enough
						resp.error = :truncated
					end
					break
				end

				# This is a dirty hack for broken HTTP servers
				if rv == Packet::ParseCode::Completed
					rbody = resp.body
					rbufq = resp.bufq

					rblob = rbody.to_s + rbufq.to_s
					tries = 0
					begin
						# XXX: This doesn't deal with chunked encoding or "Content-type: text/html; charset=..."
						while tries < 1000 and resp.headers["Content-Type"]== "text/html" and rblob !~ /<\/html>/i
							buff = conn.get_once(-1, 0.05)
							break if not buff
							rblob += buff
							tries += 1
						end
					rescue ::Errno::EPIPE, ::EOFError, ::IOError
					end

					resp.bufq = ""
					resp.body = rblob
				end
			end
		end

		return resp if not resp

		# As a last minute hack, we check to see if we're dealing with a 100 Continue here.
		# Most of the time this is handled by the parser via check_100()
		if resp.proto == '1.1' and resp.code == 100 and not opts[:skip_100]
			# Read the real response from the body if we found one
			# If so, our real response became the body, so we re-parse it.
			if resp.body.to_s =~ /^HTTP/
				body = resp.body
				resp = Response.new
				resp.max_data = config['read_max_data']
				rv = resp.parse(body)
			# We found a 100 Continue but didn't read the real reply yet
			# Otherwise reread the reply, but don't try this hack again
			else
				resp = read_response(t, :skip_100 => true)
			end
		end

		resp
	end

	#
	# Cleans up any outstanding connections and other resources.
	#
	def stop
		close
	end

	#
	# Returns whether or not the conn is valid.
	#
	def conn?
		conn != nil
	end

	#
	# Whether or not connections should be pipelined.
	#
	def pipelining?
		pipeline
	end

	#
	# Return the Authorization basic-auth header
	#
	def set_basic_auth_header(auth)
		auth ? set_formatted_header("Authorization", "Basic " + Rex::Text.encode_base64(auth)) : ""
	end

	#
	# The client request configuration
	#
	attr_accessor :config
	#
	# The client request configuration classes
	#
	attr_accessor :config_types
	#
	# Whether or not pipelining is in use.
	#
	attr_accessor :pipeline
	#
	# The local host of the client.
	#
	attr_accessor :local_host
	#
	# The local port of the client.
	#
	attr_accessor :local_port
	#
	# The underlying connection.
	#
	attr_accessor :conn
	#
	# The calling context to pass to the socket
	#
	attr_accessor :context
	#
	# The proxy list
	#
	attr_accessor :proxies

	# Auth
	attr_accessor :username, :password


	# When parsing the request, thunk off the first response from the server, since junk
	attr_accessor :junk_pipeline

protected

	# https
	attr_accessor :ssl, :ssl_version # :nodoc:

	attr_accessor :hostname, :port # :nodoc:


end

end
end
end

