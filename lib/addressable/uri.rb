#--
# Addressable, Copyright (c) 2006-2007 Bob Aman
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#++

module Addressable
  # This is an implementation of a URI parser based on RFC 3986.
  class URI
    # Raised if something other than a uri is supplied.
    class InvalidURIError < StandardError
    end
    
    # Raised if an invalid method option is supplied.
    class InvalidOptionError < StandardError
    end
    
    # Raised if an invalid method option is supplied.
    class InvalidTemplateValue < StandardError
    end

    module CharacterClasses
      ALPHA = "a-zA-Z"
      DIGIT = "0-9"
      GEN_DELIMS = "\\:\\/\\?\\#\\[\\]\\@"
      SUB_DELIMS = "\\!\\$\\&\\'\\(\\)\\*\\+\\,\\;\\="
      RESERVED = GEN_DELIMS + SUB_DELIMS
      UNRESERVED = ALPHA + DIGIT + "\\-\\.\\_\\~"
      PCHAR = UNRESERVED + SUB_DELIMS + "\\:\\@"
      SCHEME = ALPHA + DIGIT + "\\-\\+\\."
      AUTHORITY = PCHAR
      PATH = PCHAR + "\\/"
      QUERY = PCHAR + "\\/\\?"
      FRAGMENT = PCHAR + "\\/\\?"
    end    
    
    # Returns a URI object based on the parsed string.
    def self.parse(uri_string)
      return nil if uri_string.nil?
      
      # If a URI object is passed, just return itself.
      return uri_string if uri_string.kind_of?(self)
      
      # If a URI object of the Ruby standard library variety is passed,
      # convert it to a string, then parse the string.
      if uri_string.class.name =~ /^URI::/
        uri_string = uri_string.to_s
      end
      
      uri_regex =
        /^(([^:\/?#]+):)?(\/\/([^\/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?/
      scan = uri_string.scan(uri_regex)
      fragments = scan[0]
      return nil if fragments.nil?
      scheme = fragments[1]
      authority = fragments[3]
      path = fragments[4]
      query = fragments[6]
      fragment = fragments[8]
      userinfo = nil
      user = nil
      password = nil
      host = nil
      port = nil
      if authority != nil
        userinfo = authority.scan(/^([^\[\]]*)@/).flatten[0]
        if userinfo != nil
          user = userinfo.strip.scan(/^([^:]*):?/).flatten[0]
          password = userinfo.strip.scan(/:(.*)$/).flatten[0]
        end
        host = authority.gsub(/^([^\[\]]*)@/, "").gsub(/:([^:@\[\]]*?)$/, "")
        port = authority.scan(/:([^:@\[\]]*?)$/).flatten[0]
      end
      if port.nil? || port == ""
        port = nil
      end
      
      # WARNING: Not standards-compliant, but follows the theme
      # of Postel's law:
      #
      # Special exception for dealing with the retarded idea of the
      # feed pseudo-protocol.  Without this exception, the parser will read
      # the URI as having a blank port number, instead of as having a second
      # URI embedded within.  This exception translates these broken URIs
      # and instead treats the inner URI as opaque.
      if scheme == "feed" && host == "http"
        userinfo = nil
        user = nil
        password = nil
        host = nil
        port = nil
        path = authority + path
      end
      
      return Addressable::URI.new(
        scheme, user, password, host, port, path, query, fragment)
    end
    
    # Converts a path to a file protocol URI.  If the path supplied is
    # relative, it will be returned as a relative URI.  If the path supplied
    # is actually a URI, it will return the parsed URI.
    def self.convert_path(path)
      return nil if path.nil?
      
      converted_uri = path.strip
      if converted_uri.length > 0 && converted_uri[0..0] == "/"
        converted_uri = "file://" + converted_uri
      end
      if converted_uri.length > 0 &&
          converted_uri.scan(/^[a-zA-Z]:[\\\/]/).size > 0
        converted_uri = "file:///" + converted_uri
      end
      converted_uri.gsub!(/^file:\/*/i, "file:///")
      if converted_uri =~ /^file:/i
        # Adjust windows-style uris
        converted_uri.gsub!(/^file:\/\/\/([a-zA-Z])\|/i, 'file:///\1:')
        converted_uri.gsub!(/\\/, '/')
        converted_uri = self.parse(converted_uri).normalize
        if File.exists?(converted_uri.path) &&
            File.stat(converted_uri.path).directory?
          converted_uri.path.gsub!(/\/$/, "")
          converted_uri.path = converted_uri.path + '/'
        end
      else
        converted_uri = self.parse(converted_uri)
      end
      
      return converted_uri
    end
    
    # Expands a URI template into a full URI.
    #
    # An optional processor object may be supplied.  The object should
    # respond to either the :validate or :transform messages or both.
    # Both the :validate and :transform methods should take two parameters:
    # :name and :value.  The :validate method should return true or false;
    # true if the value of the variable is valid, false otherwise.  The
    # :transform method should return the transformed variable value as a
    # string.
    #
    # An example:
    #    
    #  class ExampleProcessor
    #    def self.validate(name, value)
    #      return !!(value =~ /^[\w ]+$/) if name == "query"
    #      return true
    #    end
    #    
    #    def self.transform(name, value)
    #      return value.gsub(/ /, "+") if name == "query"
    #      return value
    #    end
    #  end
    # 
    #  Addressable::URI.expand_template(
    #    "http://example.com/search/{query}/",
    #    {"query" => "an example search query"},
    #    ExampleProcessor).to_s
    #  => "http://example.com/search/an+example+search+query/"
    def self.expand_template(pattern, mapping, processor=nil)
      result = pattern.dup
      for name, value in mapping
        transformed_value = value
        if processor != nil
          if processor.respond_to?(:validate)
            if !processor.validate(name, value)
              raise InvalidTemplateValue,
                "(#{name}, #{value}) is an invalid template value."
            end
          end
          if processor.respond_to?(:transform)
            transformed_value = processor.transform(name, value)
          end
        end

        # Handle percent escaping
        transformed_value = self.encode_segment(transformed_value,
          Addressable::URI::CharacterClasses::RESERVED +
          Addressable::URI::CharacterClasses::UNRESERVED)
        
        result.gsub!(/\{#{Regexp.escape(name)}\}/, transformed_value)
      end
      result.gsub!(/\{[#{CharacterClasses::UNRESERVED}]+\}/, "")
      return Addressable::URI.parse(result)
    end
    
    # Joins several uris together.
    def self.join(*uris)
      uri_objects = uris.collect do |uri|
        uri.kind_of?(self) ? uri : self.parse(uri.to_s)
      end
      result = uri_objects.shift.dup
      for uri in uri_objects
        result.merge!(uri)
      end
      return result
    end
    
    # Percent encodes a URI segment.  Returns a string.  Takes an optional
    # character class parameter, which should be specified as a string
    # containing a regular expression character class (not including the
    # surrounding square brackets).  The character class parameter defaults
    # to the reserved plus unreserved character classes specified in
    # RFC 3986.  Usage of the constants within the CharacterClasses module is
    # highly recommended when using this method.
    #
    # An example:
    #
    #  Addressable::URI.escape_segment("simple-example", "b-zB-Z0-9")
    #  => "simple%2Dex%61mple"
    def self.encode_segment(segment, character_class=
        Addressable::URI::CharacterClasses::RESERVED +
        Addressable::URI::CharacterClasses::UNRESERVED)
      return nil if segment.nil?
      return segment.gsub(
        /[^#{character_class}]/
      ) do |sequence|
        ("%" + sequence.unpack('C')[0].to_s(16).upcase)
      end      
    end
    
    # Unencodes any percent encoded characters within a URI segment.
    # Returns a string.
    def self.unencode_segment(segment)
      return nil if segment.nil?
      return segment.to_s.gsub(/%[0-9a-f]{2}/i) do |sequence|
        sequence[1..3].to_i(16).chr
      end
    end
    
    # Percent encodes any special characters in the URI.  This method does
    # not take IRIs or IDNs into account.
    def self.encode(uri)
      uri_object = uri.kind_of?(self) ? uri : self.parse(uri.to_s)
      return Addressable::URI.new(
        self.encode_segment(uri_object.scheme,
          Addressable::URI::CharacterClasses::SCHEME),
        self.encode_segment(uri_object.user,
          Addressable::URI::CharacterClasses::AUTHORITY),
        self.encode_segment(uri_object.password,
          Addressable::URI::CharacterClasses::AUTHORITY),
        self.encode_segment(uri_object.host,
          Addressable::URI::CharacterClasses::AUTHORITY),
        self.encode_segment(uri_object.specified_port,
          Addressable::URI::CharacterClasses::AUTHORITY),
        self.encode_segment(uri_object.path,
          Addressable::URI::CharacterClasses::PATH),
        self.encode_segment(uri_object.query,
          Addressable::URI::CharacterClasses::QUERY),
        self.encode_segment(uri_object.fragment,
          Addressable::URI::CharacterClasses::FRAGMENT)
      ).to_s
    end
    
    class << self
      alias_method :escape, :encode
    end
    
    # Normalizes the encoding of a URI.  Characters within a hostname are
    # not percent encoded to allow for internationalized domain names.
    def self.normalized_encode(uri)
      uri_object = uri.kind_of?(self) ? uri : self.parse(uri.to_s)
      segments = {
        :scheme => self.unencode_segment(uri_object.scheme),
        :user => self.unencode_segment(uri_object.user),
        :password => self.unencode_segment(uri_object.password),
        :host => self.unencode_segment(uri_object.host),
        :port => self.unencode_segment(uri_object.specified_port),
        :path => self.unencode_segment(uri_object.path),
        :query => self.unencode_segment(uri_object.query),
        :fragment => self.unencode_segment(uri_object.fragment)
      }
      if URI::IDNA.send(:use_libidn?)
        segments.each do |key, value|
          if value != nil
            segments[key] = IDN::Stringprep.nfkc_normalize(value.to_s)
          end
        end
      end
      return Addressable::URI.new(
        self.encode_segment(segments[:scheme],
          Addressable::URI::CharacterClasses::SCHEME),
        self.encode_segment(segments[:user],
          Addressable::URI::CharacterClasses::AUTHORITY),
        self.encode_segment(segments[:password],
          Addressable::URI::CharacterClasses::AUTHORITY),
        segments[:host],
        segments[:port],
        self.encode_segment(segments[:path],
          Addressable::URI::CharacterClasses::PATH),
        self.encode_segment(segments[:query],
          Addressable::URI::CharacterClasses::QUERY),
        self.encode_segment(segments[:fragment],
          Addressable::URI::CharacterClasses::FRAGMENT)
      ).to_s
    end

    # Extracts uris from an arbitrary body of text.
    def self.extract(text, options={})
      defaults = {:base => nil, :parse => false} 
      options = defaults.merge(options)
      raise InvalidOptionError unless (options.keys - defaults.keys).empty?
      # This regular expression needs to be less forgiving or else it would
      # match virtually all text.  Which isn't exactly what we're going for.
      extract_regex = /((([a-z\+]+):)[^ \n\<\>\"\\]+[\w\/])/
      extracted_uris =
        text.scan(extract_regex).collect { |match| match[0] }
      sgml_extract_regex = /<[^>]+href=\"([^\"]+?)\"[^>]*>/
      sgml_extracted_uris =
        text.scan(sgml_extract_regex).collect { |match| match[0] }
      extracted_uris.concat(sgml_extracted_uris - extracted_uris)
      textile_extract_regex = /\".+?\":([^ ]+\/[^ ]+)[ \,\.\;\:\?\!\<\>\"]/i
      textile_extracted_uris =
        text.scan(textile_extract_regex).collect { |match| match[0] }
      extracted_uris.concat(textile_extracted_uris - extracted_uris)
      parsed_uris = []
      base_uri = nil
      if options[:base] != nil
        base_uri = options[:base] if options[:base].kind_of?(self)
        base_uri = self.parse(options[:base].to_s) if base_uri == nil
      end
      for uri_string in extracted_uris
        begin
          if base_uri == nil
            parsed_uris << self.parse(uri_string)
          else
            parsed_uris << (base_uri + self.parse(uri_string))
          end
        rescue Exception
          nil
        end
      end
      parsed_uris.reject! do |uri|
        (uri.scheme =~ /T\d+/ ||
         uri.scheme == "xmlns" ||
         uri.scheme == "xml" ||
         uri.scheme == "thr" ||
         uri.scheme == "this" ||
         uri.scheme == "float" ||
         uri.scheme == "user" ||
         uri.scheme == "username" ||
         uri.scheme == "out")
      end
      if options[:parse]
        return parsed_uris
      else
        return parsed_uris.collect { |uri| uri.to_s }
      end
    end
    
    # Creates a new uri object from component parts.  Passing nil for
    # any of these parameters is acceptable.
    def initialize(scheme, user, password, host, port, path, query, fragment)
      @scheme = scheme
      @scheme = nil if @scheme.to_s.strip == ""
      @user = user
      @password = password
      @host = host
      @specified_port = port.to_s
      @port = port
      @port = @port.to_s if @port.kind_of?(Fixnum)
      if @port != nil && !(@port =~ /^\d+$/)
        raise InvalidURIError,
          "Invalid port number: #{@port.inspect}"
      end
      @port = @port.to_i
      @port = nil if @port == 0
      @path = path
      @query = query
      @fragment = fragment

      validate()
    end
    
    # Returns the scheme (protocol) for this URI.
    def scheme
      return @scheme
    end
    
    # Sets the scheme (protocol for this URI.)
    def scheme=(new_scheme)
      @scheme = new_scheme
    end
    
    # Returns the user for this URI.
    def user
      return @user
    end
    
    # Sets the user for this URI.
    def user=(new_user)
      @user = new_user

      # You can't have a nil user with a non-nil password
      if @password != nil
        @user = "" if @user.nil?
      end

      # Reset dependant values
      @userinfo = nil
      @authority = nil

      # Ensure we haven't created an invalid URI
      validate()
    end
    
    # Returns the password for this URI.
    def password
      return @password
    end

    # Sets the password for this URI.
    def password=(new_password)
      @password = new_password

      # You can't have a nil user with a non-nil password
      if @password != nil
        @user = "" if @user.nil?
      end

      # Reset dependant values
      @userinfo = nil
      @authority = nil

      # Ensure we haven't created an invalid URI
      validate()
    end
    
    # Returns the username and password segment of this URI.
    def userinfo
      if !defined?(@userinfo) || @userinfo.nil?
        current_user = self.user
        current_password = self.password
        if current_user == nil && current_password == nil
          @userinfo = nil
        elsif current_user != nil && current_password == nil
          @userinfo = "#{current_user}"
        elsif current_user != nil && current_password != nil
          @userinfo = "#{current_user}:#{current_password}"
        end
      end
      return @userinfo
    end
    
    # Sets the username and password segment of this URI.
    def userinfo=(new_userinfo)
      new_user = new_userinfo.to_s.strip.scan(/^(.*):/).flatten[0]
      new_password = new_userinfo.to_s.strip.scan(/:(.*)$/).flatten[0]
      
      # Password assigned first to ensure validity in case of nil
      self.password = new_password
      self.user = new_user

      # Reset dependant values
      @authority = nil

      # Ensure we haven't created an invalid URI
      validate()
    end
    
    # Returns the host for this URI.
    def host
      return @host
    end
    
    # Sets the host for this URI.
    def host=(new_host)
      @host = new_host

      # Reset dependant values
      @authority = nil

      # Ensure we haven't created an invalid URI
      validate()
    end
    
    # Returns the authority segment of this URI.
    def authority
      if !defined?(@authority) || @authority.nil?
        return nil if self.host.nil?
        @authority = ""
        if self.userinfo != nil
          @authority << "#{self.userinfo}@"
        end
        @authority << self.host
        if self.specified_port != nil
          @authority << ":#{self.specified_port}"
        end
      end
      return @authority
    end
    
    # Sets the authority segment of this URI.
    def authority=(new_authority)
      if new_authority != nil
        new_userinfo = new_authority.scan(/^([^\[\]]*)@/).flatten[0]
        if new_userinfo != nil
          new_user = new_userinfo.strip.scan(/^([^:]*):?/).flatten[0]
          new_password = new_userinfo.strip.scan(/:(.*)$/).flatten[0]
        end
        new_host =
          new_authority.gsub(/^([^\[\]]*)@/, "").gsub(/:([^:@\[\]]*?)$/, "")
        new_port =
          new_authority.scan(/:([^:@\[\]]*?)$/).flatten[0]
      end
      new_port = nil if new_port == ""
      
      # Password assigned first to ensure validity in case of nil
      self.password = new_password
      self.user = new_user
      self.host = new_host
      
      # Port reset to allow port normalization
      @port = nil
      @specified_port = new_port
      
      # Ensure we haven't created an invalid URI
      validate()
    end

    # Returns an array of known ip-based schemes.  These schemes typically
    # use a similar URI form:
    # //<user>:<password>@<host>:<port>/<url-path>
    def self.ip_based_schemes
      return self.scheme_mapping.keys
    end

    # Returns a hash of common IP-based schemes and their default port
    # numbers.  Adding new schemes to this hash, as necessary, will allow
    # for better URI normalization.
    def self.scheme_mapping
      if !defined?(@protocol_mapping) || @protocol_mapping.nil?
        @protocol_mapping = {
          "http" => 80,
          "https" => 443,
          "ftp" => 21,
          "tftp" => 69,
          "ssh" => 22,
          "svn+ssh" => 22,
          "telnet" => 23,
          "nntp" => 119,
          "gopher" => 70,
          "wais" => 210,
          "ldap" => 389,
          "prospero" => 1525
        }
      end
      return @protocol_mapping
    end
    
    # Returns the port number for this URI.  This method will normalize to the
    # default port for the URI's scheme if the port isn't explicitly specified
    # in the URI.
    def port
      if @port.to_i == 0
        if self.scheme.nil?
          @port = nil
        else
          @port = self.class.scheme_mapping[self.scheme.strip.downcase]
        end
        return @port
      else
        @port = @port.to_i
        return @port
      end
    end
    
    # Sets the port for this URI.
    def port=(new_port)
      @port = new_port.to_s.to_i
      @specified_port = @port
      @authority = nil
    end
    
    # Returns the port number that was actually specified in the URI string.
    def specified_port
      port = @specified_port.to_s.to_i
      if port == 0
        return nil
      else
        return port
      end
    end
    
    # Returns the path for this URI.
    def path
      return @path
    end
    
    # Sets the path for this URI.
    def path=(new_path)
      @path = new_path
    end

    # Returns the basename, if any, of the file at the path being referenced.
    # Returns nil if there is no path component.
    def basename
      return nil if self.path == nil
      return File.basename(self.path).gsub(/;[^\/]*$/, "")
    end
        
    # Returns the extension, if any, of the file at the path being referenced.
    # Returns "" if there is no extension or nil if there is no path
    # component.
    def extname
      return nil if self.path == nil
      return File.extname(self.basename.gsub(/;[^\/]*$/, ""))
    end
    
    # Returns the query string for this URI.
    def query
      return @query
    end
    
    # Sets the query string for this URI.
    def query=(new_query)
      @query = new_query
    end
    
    # Returns the fragment for this URI.
    def fragment
      return @fragment
    end
    
    # Sets the fragment for this URI.
    def fragment=(new_fragment)
      @fragment = new_fragment
    end
    
    # Returns true if the URI uses an IP-based protocol.
    def ip_based?
      return false if self.scheme.nil?
      return self.class.ip_based_schemes.include?(self.scheme.strip.downcase)
    end
    
    # Returns true if this URI is known to be relative.
    def relative?
      return self.scheme.nil?
    end
    
    # Returns true if this URI is known to be absolute.
    def absolute?
      return !relative?
    end
    
    # Joins two URIs together.
    def +(uri)
      if !uri.kind_of?(self.class)
        uri = URI.parse(uri.to_s)
      end
      if uri.to_s == ""
        return self.dup
      end
      
      joined_scheme = nil
      joined_user = nil
      joined_password = nil
      joined_host = nil
      joined_port = nil
      joined_path = nil
      joined_query = nil
      joined_fragment = nil
      
      # Section 5.2.2 of RFC 3986
      if uri.scheme != nil
        joined_scheme = uri.scheme
        joined_user = uri.user
        joined_password = uri.password
        joined_host = uri.host
        joined_port = uri.specified_port
        joined_path = self.class.normalize_path(uri.path)
        joined_query = uri.query
      else
        if uri.authority != nil
          joined_user = uri.user
          joined_password = uri.password
          joined_host = uri.host
          joined_port = uri.specified_port
          joined_path = self.class.normalize_path(uri.path)
          joined_query = uri.query
        else
          if uri.path == nil || uri.path == ""
            joined_path = self.path
            if uri.query != nil
              joined_query = uri.query
            else
              joined_query = self.query
            end
          else
            if uri.path[0..0] == "/"
              joined_path = self.class.normalize_path(uri.path)
            else
              base_path = self.path.nil? ? "" : self.path.dup
              base_path = self.class.normalize_path(base_path)
              base_path.gsub!(/\/[^\/]+$/, "/")
              joined_path = self.class.normalize_path(base_path + uri.path)
            end
            joined_query = uri.query
          end
          joined_user = self.user
          joined_password = self.password
          joined_host = self.host
          joined_port = self.specified_port
        end
        joined_scheme = self.scheme
      end
      joined_fragment = uri.fragment
      
      return Addressable::URI.new(
        joined_scheme,
        joined_user,
        joined_password,
        joined_host,
        joined_port,
        joined_path,
        joined_query,
        joined_fragment
      )
    end
    
    # Merges two URIs together.
    def merge(uri)
      return self + uri
    end
    
    # Destructive form of merge.
    def merge!(uri)
      replace_self(self.merge(uri))
    end
    
    # Returns the shortest normalized relative form of this URI that uses the
    # supplied URI as a base for resolution.  Returns an absolute URI if
    # necessary.
    def route_from(uri)
      uri = uri.kind_of?(self.class) ? uri : self.class.parse(uri.to_s)
      uri = uri.normalize
      normalized_self = self.normalize
      if normalized_self.relative?
        raise ArgumentError, "Expected absolute URI, got: #{self.to_s}"
      end
      if uri.relative?
        raise ArgumentError, "Expected absolute URI, got: #{self.to_s}"
      end
      if normalized_self == uri
        return Addressable::URI.parse("##{normalized_self.fragment}")
      end
      segments = normalized_self.to_h
      if normalized_self.scheme == uri.scheme
        segments[:scheme] = nil
        if normalized_self.authority == uri.authority
          segments[:user] = nil
          segments[:password] = nil
          segments[:host] = nil
          segments[:port] = nil
          if normalized_self.path == uri.path
            segments[:path] = nil
            if normalized_self.query == uri.query
              segments[:query] = nil
            end
          end
        end
      end
      # Avoid network-path references.
      if segments[:scheme] == nil && segments[:host] != nil
        segments[:scheme] = normalized_self.scheme
      end
      return Addressable::URI.new(
        segments[:scheme],
        segments[:user],
        segments[:password],
        segments[:host],
        segments[:port],
        segments[:path],
        segments[:query],
        segments[:fragment]
      )
    end
    
    # Returns the shortest normalized relative form of the supplied URI that
    # uses this URI as a base for resolution.  Returns an absolute URI if
    # necessary.
    def route_to(uri)
      uri = uri.kind_of?(self.class) ? uri : self.class.parse(uri.to_s)
      return uri.route_from(self)
    end
    
    # Returns a normalized URI object.
    #
    # NOTE: This method does not attempt to fully conform to specifications.
    # It exists largely to correct other people's failures to read the
    # specifications, and also to deal with caching issues since several
    # different URIs may represent the same resource and should not be
    # cached multiple times.
    def normalize
      normalized_scheme = nil
      normalized_scheme = self.scheme.strip.downcase if self.scheme != nil
      normalized_scheme = "svn+ssh" if normalized_scheme == "ssh+svn"
      if normalized_scheme == "feed"
        if self.to_s =~ /^feed:\/*http:\/*/
          return self.class.parse(
            self.to_s.scan(/^feed:\/*(http:\/*.*)/).flatten[0]).normalize
        end
      end
      normalized_user = nil
      normalized_user = self.user.strip if self.user != nil
      normalized_password = nil
      normalized_password = self.password.strip if self.password != nil
      normalized_host = nil
      normalized_host = self.host.strip.downcase if self.host != nil
      if normalized_host != nil
        begin
          normalized_host = URI::IDNA.to_ascii(normalized_host)
        rescue Exception
          nil
        end
      end
      
      normalized_port = self.port
      if self.class.scheme_mapping[normalized_scheme] == normalized_port
        normalized_port = nil
      end
      normalized_path = nil
      normalized_path = self.path.strip if self.path != nil
      if normalized_path == nil &&
          normalized_scheme != nil &&
          normalized_host != nil
        normalized_path = "/"
      end
      if normalized_path != nil
        normalized_path = self.class.normalize_path(normalized_path)
      end
      if normalized_path == ""
        if ["http", "https", "ftp", "tftp"].include?(normalized_scheme)
          normalized_path = "/"
        end
      end

      normalized_query = nil
      normalized_query = self.query.strip if self.query != nil

      normalized_fragment = nil
      normalized_fragment = self.fragment.strip if self.fragment != nil
      return Addressable::URI.parse(
        Addressable::URI.normalized_encode(Addressable::URI.new(
          normalized_scheme,
          normalized_user,
          normalized_password,
          normalized_host,
          normalized_port,
          normalized_path,
          normalized_query,
          normalized_fragment
        )))
    end

    # Destructively normalizes this URI object.
    def normalize!
      replace_self(self.normalize)
    end
    
    # Creates a URI suitable for display to users.  If semantic attacks are
    # likely, the application should try to detect these and warn the user.
    # See RFC 3986 section 7.6 for more information.
    def display_uri
      display_uri = self.normalize
      begin
        display_uri.instance_variable_set("@host",
          URI::IDNA.to_unicode(display_uri.host))
      rescue Exception
        nil
      end
      return display_uri
    end
    
    # Returns true if the URI objects are equal.  This method normalizes
    # both URIs before doing the comparison, and allows comparison against
    # strings.
    def ===(uri)
      uri_string = nil
      if uri.respond_to?(:normalize)
        uri_string = uri.normalize.to_s
      else
        begin
          uri_string = URI.parse(uri.to_s).normalize.to_s
        rescue Exception
          return false
        end
      end
      return self.normalize.to_s == uri_string
    end
    
    # Returns true if the URI objects are equal.  This method normalizes
    # both URIs before doing the comparison.
    def ==(uri)
      return false unless uri.kind_of?(self.class) 
      return self.normalize.to_s == uri.normalize.to_s
    end

    # Returns true if the URI objects are equal.  This method does NOT
    # normalize either URI before doing the comparison.
    def eql?(uri)
      return false unless uri.kind_of?(self.class) 
      return self.to_s == uri.to_s
    end
    
    # Clones the URI object.
    def dup
      duplicated_scheme = nil
      duplicated_scheme = self.scheme.dup if self.scheme != nil
      duplicated_user = nil
      duplicated_user = self.user.dup if self.user != nil
      duplicated_password = nil
      duplicated_password = self.password.dup if self.password != nil
      duplicated_host = nil
      duplicated_host = self.host.dup if self.host != nil
      duplicated_port = self.port
      duplicated_path = nil
      duplicated_path = self.path.dup if self.path != nil
      duplicated_query = nil
      duplicated_query = self.query.dup if self.query != nil
      duplicated_fragment = nil
      duplicated_fragment = self.fragment.dup if self.fragment != nil
      duplicated_uri = Addressable::URI.new(
        duplicated_scheme,
        duplicated_user,
        duplicated_password,
        duplicated_host,
        duplicated_port,
        duplicated_path,
        duplicated_query,
        duplicated_fragment
      )
      @specified_port = nil if !defined?(@specified_port)
      duplicated_uri.instance_variable_set("@specified_port", @specified_port)
      return duplicated_uri
    end
    
    # Returns the assembled URI as a string.
    def to_s
      uri_string = ""
      uri_string << "#{self.scheme}:" if self.scheme != nil
      uri_string << "//#{self.authority}" if self.authority != nil
      uri_string << self.path.to_s
      uri_string << "?#{self.query}" if self.query != nil
      uri_string << "##{self.fragment}" if self.fragment != nil
      return uri_string
    end
    
    # Returns a Hash of the URI segments.
    def to_h
      return {
        :scheme => self.scheme,
        :user => self.user,
        :password => self.password,
        :host => self.host,
        :port => self.specified_port,
        :path => self.path,
        :query => self.query,
        :fragment => self.fragment
      }
    end
    
    # Returns a string representation of the URI object's state.
    def inspect
      sprintf("#<%s:%#0x URI:%s>", self.class.to_s, self.object_id, self.to_s)
    end
    
    # This module handles internationalized domain names.  When Ruby has an
    # implementation of nameprep, stringprep, punycode, etc, this
    # module should contain an actual implementation of IDNA instead of
    # returning nil if libidn can't be used.
    module IDNA
      # Returns the ascii representation of the label.
      def self.to_ascii(label)
        return nil if label.nil?
        if self.use_libidn?
          return IDN::Idna.toASCII(label)
        else
          raise NotImplementedError,
            "There is no available pure-ruby implementation.  " +
            "Install libidn bindings."
        end
      end
      
      # Returns the unicode representation of the label.
      def self.to_unicode(label)
        return nil if label.nil?
        if self.use_libidn?
          return IDN::Idna.toUnicode(label)
        else
          raise NotImplementedError,
            "There is no available pure-ruby implementation.  " +
            "Install libidn bindings."
        end
      end
      
    private
      # Determines if the libidn bindings are available and able to be used.
      def self.use_libidn?
        if !defined?(@use_libidn) || @use_libidn.nil?
          begin
            require 'rubygems'
          rescue LoadError
            nil
          end
          begin
            require 'idn'
          rescue LoadError
            nil
          end
          @use_libidn = !!(defined?(IDN::Idna))
        end
        return @use_libidn
      end
    end
    
  private
    # Resolves paths to their simplest form.
    def self.normalize_path(path)
      return nil if path.nil?
      normalized_path = path.dup
      previous_state = normalized_path.dup
      begin
        previous_state = normalized_path.dup
        normalized_path.gsub!(/\/\.\//, "/")
        normalized_path.gsub!(/\/\.$/, "/")
        parent = normalized_path.scan(/\/([^\/]+)\/\.\.\//).flatten[0]
        if parent != "." && parent != ".."
          normalized_path.gsub!(/\/#{parent}\/\.\.\//, "/")
        end
        parent = normalized_path.scan(/\/([^\/]+)\/\.\.$/).flatten[0]
        if parent != "." && parent != ".."
          normalized_path.gsub!(/\/#{parent}\/\.\.$/, "/")
        end
        normalized_path.gsub!(/^\.\.?\/?/, "")
        normalized_path.gsub!(/^\/\.\.?\//, "/")
      end until previous_state == normalized_path
      return normalized_path
    end

    # Ensures that the URI is valid.
    def validate
      if self.scheme == nil && self.user == nil && self.password == nil &&
          self.host == nil && self.port == nil && self.path == nil &&
          self.query == nil && self.fragment == nil
        raise InvalidURIError, "All segments were nil."
      end
      if self.scheme != nil &&
          (self.host == nil || self.host == "") &&
          (self.path == nil || self.path == "")
        raise InvalidURIError,
          "Absolute URI missing hierarchical segment."
      end
    end
    
    # Replaces the internal state of self with the specified URI's state.
    # Used in destructive operations to avoid massive code repetition.
    def replace_self(uri)
      # Reset dependant values
      @userinfo = nil
      @authority = nil
      
      @scheme = uri.scheme
      @user = uri.user
      @password = uri.password
      @host = uri.host
      @specified_port = uri.instance_variable_get("@specified_port")
      @port = @specified_port.to_s.to_i
      @path = uri.path
      @query = uri.query
      @fragment = uri.fragment
      return self
    end
  end
end
