require 'lazyauth/state'
require 'pathname'
require 'commander'
require 'yaml'
require 'iso8601'
require 'uri'
require 'dry-schema'
require 'deep_merge'

module LazyAuth

  module Types
    include Dry::Types()

    Duration = Types.Constructor(ISO8601::Duration) do |x|
      begin
        out = ISO8601::Duration.new x.to_s.strip.upcase
      rescue ISO8601::Errors::UnknownPattern => e
        raise Dry::Types::CoercionError.new e
      end

      out
    end

    ASCII = /^[A-Za-z_][0-9A-Za-z_.-]*$/

    # okay so this shit doesn't seem to work

    ASCIIToken = Strict::String.constrained(format: ASCII).constructor(&:strip)

    URI = Types.Constructor(::URI) do |x|
      begin
        out = URI(x)
      rescue URI::InvalidURIError => e
        raise Dry::Types::CoercionError.new e
      end

      out
    end

    # should be WritablePathname but whatever
    Pathname = Types.Constructor(::Pathname) do |x|
      out = Pathname(x)
      dir = out.expand_path.dirname
      raise Dry::Types::CoercionError.new "#{dir} is not writable" unless
        dir.writable?
      raise Dry::Types::CoercionError.new "#{out} can't be overwritten" if
        out.exist? and !out.writable?
      out
    end
    # actually pretty sure i can define constraints for this type, oh well

    HN = /^(?:[0-9a-z-]+(?:\.[0-9a-z-]+)*|[0-9a-f]{,4}(?::[0-9a-f]{,4}){,7})$/i

    Hostname = String.constructor(&:strip).constrained(format: HN)
  end

  Config = Dry::Schema.Params do
    required(:dsn).value    Types::String
    optional(:base).value   Types::URI
    # whaaaaat the f the friggin type decl is supposed to take care of this
    required(:query).filter(format?:  Types::ASCII).value Types::ASCIIToken
    required(:cookie).filter(format?: Types::ASCII).value Types::ASCIIToken
    #required(:cookie).value Types::ASCIIToken

    required(:expiry).hash do
      required(:url).value    Types::Duration
      required(:cookie).value Types::Duration
    end

    required(:vars).hash do
      required(:user).filter(format?:     Types::ASCII).value Types::ASCIIToken
      required(:redirect).filter(format?: Types::ASCII).value Types::ASCIIToken
    end

    required(:host).filter(format?: Types::HN).value Types::Hostname
    required(:port).value Types::Integer
    optional(:pid).value Types::Pathname
  end

  class CLI
    include Commander::Methods

    private

    ONE_YEAR = ISO8601::Duration.new('P1Y').freeze

    CFG_FILE = Pathname('lazyauth.yml').freeze

    DEFAULTS = {
      dsn:    'sqlite://lazyauth.sqlite',
      query:  'knock',
      cookie: 'lazyauth',
      expiry: { url: ONE_YEAR, cookie: ONE_YEAR }.freeze,
      vars:   { user: 'FCGI_USER', redirect: 'FCGI_REDIRECT' }.freeze,
      host:   'localhost',
      port:   10101,
    }.freeze

    def normalize_hash h, strings: false, flatten: false, dup: false,
        freeze: false
      return h unless h.is_a? Hash
      out = {}
      h.each do |k, v|
        ks = k.to_s
        ks = ks.to_sym unless strings
        v = if v.is_a?(Hash)
              normalize_hash v, strings: strings, flatten: flatten,
                dup: dup, freeze: freeze
            elsif v.respond_to?(:to_a)
              v.to_a.map do |x|
                normalize_hash x, strings: strings, flatten: flatten,
                  dup: dup, freeze: freeze
              end
            elsif flatten
              v.is_a?(Numeric) ? v : v.to_s
            else
              v
            end
        v = v.dup if dup
        v = v.freeze if freeze
        out[ks] = v
      end
      out
    end

    def read_config cfg = @cfgfile, clean: true, commit: true
      unless cfg.is_a? Hash
        raise 'need a config file' unless
          cfg and (cfg.is_a?(Pathname) or cfg.respond_to?(:to_s))
        cfg = Pathname(cfg).expand_path
        if cfg.exist?
          raise "Config file #{cfg} is not readable" unless cfg.readable?
        else
          cfg = {}
        end
        cfg = YAML.load_file cfg
      end

      if clean
        cfg  = normalize_hash cfg
        test = validate_config cfg
        raise RuntimeError.new(test.errors.messages) unless test.success?
        cfg = test.to_h
      end

      merge_config @config, cfg, commit: true if commit

      cfg
    end

    def validate_config cfg
      Config.call cfg
    end

    OPTION_MAP = {
      base_url:   :base,
      query_key:  :query,
      cookie_key: :cookie,
      lifetime:   :expiry,
      listen:     :host,
    }.freeze

    def cmdline_config options
      h = options.__hash__.dup

      # do the easy ones first
      h.transform_keys! { |k| OPTION_MAP.fetch k, k }

      # prepare hashes
      exp = h.delete :expiry if h.include?(:expiry) and !h[:expiry].is_a?(Hash)
      [:vars, :expiry].each do |k|
        raise "key #{k} should be a hash" if h.include? k and !k.is_a?(Hash)
        h[k] ||= {}
      end

      # do expiry durations
      h[:expiry][:url] = h[:expiry][:cookie] = exp if exp
      [:url, :cookie].each do |which|
        hs = (which.to_s + '_expiry').to_sym
        h[:expiry][which] = h.delete hs if h.include? hs
      end

      # do fastcgi header variables
      [:user, :redirect].each do |which|
        vs = (which.to_s + '_var').to_sym
        h[:vars][which] = h.delete vs if h.include? vs
      end

      h
    end

    def merge_config *cfg, commit: false, validate: false
      raise 'wah wah need a config' unless (out = cfg.shift)
      # normalize does an implicit deep clone
      out = normalize_hash(out, dup: true)

      until cfg.empty?
        #out.deep_merge normalize_hash(cfg.shift, dup: true)
        out = normalize_hash(cfg.shift, dup: true).deep_merge out
      end

      if validate
        test = Config.call out
        if test.success?
          out = test.to_h
        else
          raise RuntimeError.new test.errors.messages
        end
      end

      @config = out if commit

      out
    end

    def write_config cfg = @config, file: @cfgfile
      out = normalize_hash cfg, strings: true, flatten: true
      file.open(?w) { |fh| fh.write out.to_yaml }
    end

    def connect dsn = @dsn
      @state = State.connect dsn
    end

    public

    def run
      program :name,        File.basename($0)
      program :version,     LazyAuth::VERSION
      program :description, 'Command line manager for LazyAuth'
      program :int_message, 'mkay bye'

      @cfgfile = CFG_FILE.expand_path
      @config  = DEFAULTS.dup

      global_option '-b', '--base-uri URI',
        'A base URI for relative references' do |o|
        @config[:base] = URI(o)
      end

      global_option '-c', '--config FILE',
        'The location of the configuration file' do |o|
        @cfgfile = Pathname(o).expand_path
      end

      global_option '-d', '--dsn STRING',
        'Specify a data source name, overriding configuration' do |o|
        @config[:dsn] = o
      end

      global_option '-D', '--debug-sql',
        'Log SQL queries to standard error' do
        @log_sql = true
      end

      command :init do |c|
        c.syntax  = "#{program :name} init [OPTIONS]"
        c.summary = 'Initializes configuration file and state database.'
        c.description = <<-DESC
This command initializes the configuration file (default `$PWD/lazyauth.yml`)
and state database (default `sqlite://lazyauth.sqlite`). Global parameters
(-b, -c, -d) will be used to record the default base URL, config file
location, and data source name, respectively.

Most configuration parameters have sane defaults, and the base URI is
optional. If an existing configuration file is found at the specified
location, you will be asked before overwriting it. Initialization will
likewise overwrite any existing database tables, so you'll also get a
chance to move those out of the way if you want to keep them.

If you are using a network-attached RDBMS (Postgres, MySQL, Oracle,
etc), you will almost certainly need to create the designated
database, user, and any applicable access rights before running this
command.
        DESC

        c.option '--query-key TOKEN', 'A URI query key; defaults to `knock`'
        c.option '--cookie-key TOKEN', 'A cookie key; defaults to `lazyauth`'
        c.option '--expiry DURATION',
          'Global default expiry, given as an ISO8601 duration (default P1Y)'
        c.option '--url-expiry DURATION',
          'Set the default expiry duration for URLs only'
        c.option '--cookie-expiry DURATION',
          'Set the default expiry duration for cookies only'
        c.option '--user-var TOKEN',
          'Environment variable name for user (default `FCGI_USER`)'
        c.option '--redirect-var TOKEN',
          'Environment variable name for redirect (default `FCGI_REDIRECT`)'
        c.option '-l', '--listen HOST',
          'Specify listening address for FastCGI daemon (default localhost)'
        c.option '-p', '--port NUMBER',
          'Specify TCP port for FastCGI daemon (default 10101)'
        c.option '-P', '--pid FILE',
          'Create a PID file when FastCGI daemon is detached'

        c.action do |_, opts|
          # check the directory where we're going to drop the config file
          dir = @cfgfile.dirname
          unless dir.exist?
            rel = dir.relative_path_from Pathname.pwd
            if agree "Directory #{rel} doesn't exist. Try to create it?"
              begin
                dir.mkpath
              rescue Errno::EACCES
                say "Could not create #{rel}. :("
                exit 1
              end
            end
          end

          # check for an existing config file
          if @cfgfile.exist?
            rel = @cfgfile.relative_path_from Pathname.pwd
            # get confirmation if config file already exists
            x = "Configuration file #{rel} already exists. Overwrite?"
            unless agree x
              say "Not overwriting #{rel}."
              exit 1
            end

            # complain if not writable
            unless @cfgfile.writable?
              say "Not overwriting #{rel}, which is not writable."
              exit 1
            end
          end

          # wrap these calls
          begin
            cfg = cmdline_config opts
            merge_config @config, cfg, commit: true, validate: true
            write_config
          rescue SystemCallError => e
            rel = @cfgfile.relative_path_from Pathname.pwd
            say "Could not write #{rel}: #{e}"
            exit 1
          #rescue OptionParser::InvalidArgument => e
          #  say "One or more of the command-line options was invalid: #{e}"
          #  exit 1
          end

          do_db = true
          begin
            state = State.new @config[:dsn], create: false, debug: @log_sql

            # check for existence of database
            if state.initialized?
              x = "Database #{@config[:dsn]} is already initialized. Overwrite?"
              unless agree x
                say "Not overwriting #{@config[:dsn]}."
                do_db = false
              end
            end

            # now create the tables
            state.initialize! if do_db

          rescue Sequel::DatabaseConnectionError => e
            # complain if database doesn't exist or if i don't have access
            say "Could not connect to #{@config[:dsn]}: #{e}"
            do_db = false
          end

          # now tell the user what i did
          say 'Created new configuration file' +
            "#{do_db ? ' and state database' : ''}."
        end
      end

      command :mint do |c|
        c.syntax = "#{program :name} [mint] [OPTIONS] USERID [URL]"
        c.summary = 'Mints a new URL associated with the given user.'
        c.description = <<-DESC
This command mints a new URL associated with the given user. If the
URL is omitted, the slug will be appended to the configured base
URL. If that is missing too, the command will just return the
generated token. If there is already an active token for this user, it
will be reused with the new URL, unless you pass -n or -x, which will
add a new

This command will create a new record for a given user ID if none is
present. You can include an optional email address (-e), or you can make
the user ID an email address, LDAP DN, Kerberos principal, or whatever
you want. The user ID, whatever it ends up as, is what will be showing
up verbatim in the `REMOTE_USER` field of downstream Web apps. Note
that this database only maps one kind of identifier to another, and is
not meant to be authoritative storage for user profiles.
        DESC

        c.option '-e', '--email EMAIL',
          'Set the email address for the (new) user'
        c.option '-l', '--lifetime DURATION',
          'How long this URL will work, as an ISO8601 duration (default P1Y)'
        c.option '-n', '--new',
          'Force minting a new token even if the current one is still fresh'
        c.option '-x', '--expire',
          'Expire any active tokens in circulation (implies --new)'
        c.option '-1', '--oneoff', 'The token will expire after the first ' +
          'time it is used (implies --new).'

        c.action do |args, opts|
          read_config
          merge_config @config, cmdline_config(opts),
            commit: true, validate: true

          user, url = *(args.map(&:strip))

          raise Commander::Runner::CommandError.new 'No user supplied' unless
            user and user != ''
          if url and url != ''
            begin
              if @config[:base]
                url = @config[:base].merge url
              else
                url = URI(url)
              end

              scheme = url.scheme.to_s.downcase

              if scheme.start_with? 'http'
                say 'Unencrypted HTTP will be insecure,' +
                  "but I assume you know what you're doing" if
                  url.scheme == 'http'
              else
                say 'Gonna be hard doing Web authentication ' +
                  "against a non-Web URL, but you're the boss!"
              end
            rescue URI::InvalidURIError => e
              raise Commander::Runner::CommandError.new e
            end
          else
            url = @config[:base]? @config[:base].dup : nil
          end

          # handle implications of expire/oneoff options
          opts.default :new => !!(opts.expire || opts.oneoff)

          begin

            # connect to the database
            state = State.new @config[:dsn], debug: @log_sql,
              query_expires:  @config[:expiry][:url],
              cookie_expires: @config[:expiry][:cookie]

            id = state.id_for user, create: true, email: opts.email

            # obtain the latest live token for this principal
            token = state.token_for id unless opts.new

            # eh i don't like this logic but it was the least-bad
            # option i could think of at the time
            if !token || opts.new
              if opts.expire
                say "Expiring all live tokens for #{user}."
                # burn all existing query-string tokens
                state.expire_tokens_for id, cookie: false

                # XXX do we put in a command-line switch for burning
                # the cookies too?
              end
              # create new token
              token = state.new_token id, oneoff: opts.oneoff,
                expires: @config[:expiry][:query]
            end

            if url
              if (query = url.query)
                query = URI::decode_www_form query
              else 
                query = []
              end

              # now add the key
              query << [@config[:query], token]

              url.query = URI::encode_www_form query

              say "Here's the link to give to #{user} (and only #{user}): " +
                url.to_s
            else
              say "No URL given, so here's your token: #{token}"
            end

            exit 0

          rescue Sequel::DatabaseConnectionError => e
            say "Could not connect to #{@config[:dsn]}: #{e}"
            exit 1
          end
        end
      end

      command :fcgi do |c|
        c.syntax = "#{program :name} fcgi [OPTIONS]"
        c.summary = 'Runs the LazyAuth FastCGI authenticator.'
        c.description = <<-DESC
This command fires up the LazyAuth FastCGI authenticator service. By
default it runs in the foreground, listening on localhost, TCP port
10101. All of these parameters of course can be changed, either in
configuration or on the command line. Of course this daemon is only
half the setup, the other half being done on the Web server, using
something like `mod_authnz_fcgi`.
        DESC
        c.option '-l', '--listen HOST',
          'Specify listening address (default localhost)'
        c.option '-p', '--port NUMBER', 'Specify TCP port (default 10101)'
        c.option '-z', '--detach', 'Detach and daemonize the process'
        c.option '-P', '--pid FILE', 'Create a PID file when detached'

        c.action do |args, opts|
          require 'lazyauth'
          require 'rack'

          read_config
          merge_config @config, cmdline_config(opts),
            commit: true, validate: true

          say 'Running authenticator daemon on ' +
            "fcgi://#{@config[:host]}:#{@config[:port]}/"

          Rack::Server.start({
            app: LazyAuth::App.new(@config[:dsn], debug: @log_sql),
            server: 'fastcgi',
            environment: 'none',
            daemonize: opts.detach,
            Host: @config[:host],
            Port: @config[:port],
          })
        end
      end

      default_command :mint

      run!
    end

    def self.run
      new.run
    end
  end
end
