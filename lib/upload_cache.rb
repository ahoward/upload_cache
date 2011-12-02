require 'fileutils'
require 'cgi'
require 'tmpdir'

require 'map'

class UploadCache
  Version = '1.2.0'

  Readme = <<-__
    NAME
      upload_cache.rb

    DESCRIPTION
      a small utility library to facility caching http file uploads between
      form validation failures.  designed for rails, but usable anywhere.

    USAGE
      in the controller

        def upload
          @upload_cache = UploadCache.for(params, :upload)

          @record = Model.new(params)

          if request.get?
            render and return
          end

          if request.post?
            @record.save!
            @upload_cache.clear!
          end
        end


      in the view

        <input type='file' name='upload />

        <%= @upload_cache.hidden %>

        <!-- optionally, you can show any uploaded upload -->

        <% if url = @upload_cache.url %>
          you already uploaded: <img src='<%= raw url %>' />
        <% end %>


      in a rake task

        UploadCache.clear!  ### nuke old files once per day

      upload_caches ***does this automatically*** at_exit{}, but you can still
      run it manually if you like.

  __

  class << UploadCache
    def version
      UploadCache::Version
    end

    def url
      @url ||= "file:/#{ root }"
    end

    def url=(url)
      @url = '/' + Array(url).join('/').squeeze('/').sub(%r|^/+|, '').sub(%r|/+$|, '')
    end

    def root
      @root ||= Dir.tmpdir
    end

    def root=(root)
      @root = File.expand_path(root)
    end

    {
      'ffi-uuid'  => proc{|*args| FFI::UUID.generate_time.to_s},
      'uuid'      => proc{|*args| UUID.generate.to_s},
      'uuidtools' => proc{|*args| UUIDTools::UUID.timestamp_create.to_s}
    }.each do |lib, implementation|
      begin
        require(lib)
        define_method(:uuid, &implementation)
        break
      rescue LoadError
        nil
      end
    end
    abort 'no suitable uuid generation library detected' unless method_defined?(:uuid)

    def tmpdir(&block)
      tmpdir = File.join(root, uuid)

      if block
        FileUtils.mkdir_p(tmpdir)
        block.call(tmpdir)
      else
        tmpdir
      end
    end

    def cleanname(path)
      basename = File.basename(path.to_s)
      CGI.unescape(basename).gsub(%r/[^0-9a-zA-Z_@)(~.-]/, '_').gsub(%r/_+/,'_')
    end

    def cache_key_for(key)
      key.clone.tap do |cache_key|
        cache_key[-1] = "#{ cache_key[-1] }_upload_cache"
      end
    end

    def finalizer(object_id)
      if fd = IOs[object_id]
        IO.for_fd(fd).close
        IOs.delete(object_id)
      end
    end

    UUIDPattern = %r/^[a-zA-Z0-9-]+$/io
    Age = 60 * 60 * 24

    def clear!(options = {})
      return if UploadCache.turd?

      glob = File.join(root, '*')
      age = Integer(options[:age] || options['age'] || Age)
      since = options[:since] || options['since'] || Time.now

      Dir.glob(glob) do |entry|
        begin
          next unless test(?d, entry)
          next unless File.basename(entry) =~ UUIDPattern

          files = Dir.glob(File.join(entry, '**/**'))

          all_files_are_old =
            files.all? do |file|
              begin
                stat = File.stat(file)
                age = since - stat.atime
                age >= Age
              rescue
                false
              end
            end

          FileUtils.rm_rf(entry) if all_files_are_old
        rescue
          next
        end
      end
    end

    at_exit{ UploadCache.clear! }

    def turd?
      @turd ||= !!ENV['UPLOAD_CACHE_TURD']
    end

    def name_for(key, &block)
      if block
        @name_for = block
      else
        defined?(@name_for) ? @name_for[key] : [prefix, *Array(key)].compact.join('.')
      end
    end

    def prefix(*value)
      @prefix = value.shift if value
      @prefix
    end

    def prefix=(value)
      @prefix = value
    end

    def default
      @default ||= Map[:url, nil, :path, nil]
    end

    def for(params, *args)
      params = Map.for(params)
      options = Map.options_for!(args)

      key = Array(options[:key] || args).flatten.compact
      key = [:upload] if key.empty?

      upload = params.get(key)

      if upload.respond_to?(:read)
        tmpdir do |tmp|
          original_basename =
            [:path, :filename, :original_path, :original_filename].
            map{|msg| upload.send(msg) if upload.respond_to?(msg)}.compact.first
          basename = cleanname(original_basename)

          path = File.join(tmp, basename)
          open(path, 'wb'){|fd| fd.write(upload.read)}
          upload_cache = UploadCache.new(key, path, options)
          params.set(key, upload_cache.io)
          return upload_cache
        end
      end

      cache_key = cache_key_for(key)
      upload_cache = params.get(cache_key)

      if upload_cache
        dirname, basename = File.split(upload_cache)
        relative_dirname = File.expand_path(File.dirname(dirname))
        relative_basename = File.join(relative_dirname, basename)
        path = root + '/' + relative_basename
        upload_cache = UploadCache.new(key, path, options)
        params.set(key, upload_cache.io)
        return upload_cache
      end

      upload_cache = UploadCache.new(key, options)
      params.set(key, upload_cache.io) if upload_cache.io
      return upload_cache
    end
  end

  attr_accessor :key
  attr_accessor :cache_key
  attr_accessor :name
  attr_accessor :path
  attr_accessor :dirname
  attr_accessor :basename
  attr_accessor :value
  attr_accessor :io
  attr_accessor :default_url
  attr_accessor :default_path

  IOs = {}

  def initialize(key, *args)
    options = Map.options_for!(args)

    @key = key
    @cache_key = UploadCache.cache_key_for(@key)
    @name = UploadCache.name_for(@cache_key)

    path = args.shift || options[:path]

    default = Map.for(options[:default])

    @default_url = default[:url] || options[:default_url] || UploadCache.default.url
    @default_path = default[:path] || options[:default_path] || UploadCache.default.path

    if path
      @path = path
      @dirname, @basename = File.split(@path)
      @value = File.join(File.basename(@dirname), @basename).strip
    else
      @path = nil
      @value = nil
    end

    if @path or @default_path
      @io = open(@path || @default_path, 'rb')
      IOs[object_id] = @io.fileno
      ObjectSpace.define_finalizer(self, UploadCache.method(:finalizer).to_proc)
    end
  end

  def url
    if @value
      File.join(UploadCache.url, @value)
    else
      @default_url ? @default_url : nil
    end
  end

  def hidden
    raw("<input type='hidden' name='#{ @name }' value='#{ @value }' class='upload_cache' />") if @value
  end

  def to_s
    hidden.to_s
  end

  module HtmlSafe
    def html_safe() self end
    def html_safe?() self end
  end

  def raw(*args)
    string = args.join
    unless string.respond_to?(:html_safe)
      string.extend(HtmlSafe)
    end
    string.html_safe
  end

  def clear!
    return if UploadCache.turd?

    begin
      FileUtils.rm_rf(@dirname) if test(?d, @dirname)
    rescue
      nil
    ensure
      @io.close rescue nil
      IOs.delete(object_id)
      Thread.new{ UploadCache.clear! }
    end
  end
end

Upload_cache = UploadCache unless defined?(Upload_cache)



if defined?(Rails.env)

  if defined?(Rails.root) and Rails.root
    UploadCache.url = '/system/uploads/cache'
    UploadCache.root = File.join(Rails.root, 'public', UploadCache.url)
  end

  unless Rails.env.production?
    if defined?(unloadable)
      unloadable(UploadCache)
    end
  end
end
