require 'fileutils'
require 'cgi'
require 'tmpdir'

require 'map'

class UploadCache
  Version = '2.1.0'

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
      @url ||= (
        if defined?(Rails.root) and Rails.root
          '/system/upload_cache'
        else
          "file:/#{ root }"
        end
      )
    end

    def url=(url)
      @url = '/' + Array(url).join('/').squeeze('/').sub(%r|^/+|, '').sub(%r|/+$|, '')
    end

    def root
      @root ||= (
        if defined?(Rails.root) and Rails.root
          File.join(Rails.root, 'public', UploadCache.url)
        else
          Dir.tmpdir
        end
      )
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
        ::IO.for_fd(fd).close rescue nil
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

    def default
      @default ||= Map[:url, nil, :path, nil]
    end

    def prefix=(value)
      @prefix = value
    end

    def cache(params, *args)
      params_map = Map.for(params)
      options = Map.options_for!(args)

      key = Array(options[:key] || args).flatten.compact
      key = [:upload] if key.empty?

      upload_cache = (
        current_upload_cache_for(params_map, key, options) or
        previous_upload_cache_for(params_map, key, options) or
        default_upload_cache_for(params_map, key, options)
      )

      value = params_map.get(key)

      update_params(params, key, value)

      upload_cache
    end
    alias_method('for', 'cache')

    def update_params(params, key, value)
      key = Array(key).flatten

      leaf = key.pop
      path = key
      node = params

      until path.empty?
        key = path.shift
        case node
          when Array
            index = Integer(key)
            break unless node[index]
            node = node[index]
          else
            break unless node.has_key?(key)
            node = node[key]
        end
      end

      node[leaf] = value
    end

    def current_upload_cache_for(params, key, options)
      upload = params.get(key)
      if upload.respond_to?(:upload_cache) and upload.upload_cache
        return upload.upload_cache
      end

      if upload.respond_to?(:read)
        tmpdir do |tmp|
          original_basename =
            [:original_path, :original_filename, :path, :filename].
              map{|msg| upload.send(msg) if upload.respond_to?(msg)}.compact.first

          basename = cleanname(original_basename)

          path = File.join(tmp, basename)

          FileUtils.rm_f(path)

          begin
            FileUtils.ln(upload.path, path)
          rescue
            open(path, 'wb'){|fd| fd.write(upload.read)}
          end

          begin
            upload.rewind
          rescue Object
            nil
          end

          upload_cache = UploadCache.new(key, path, options)
          params.set(key, upload_cache.io)
          return upload_cache
        end
      end

      nil
    end

    def previous_upload_cache_for(params, key, options)
      upload = params.get(key)
      if upload.respond_to?(:upload_cache) and upload.upload_cache
        return upload.upload_cache
      end

      upload = params.get(cache_key_for(key))

      if upload
        dirname, basename = File.split(File.expand_path(upload))
        relative_dirname = File.basename(dirname)
        relative_basename = File.join(relative_dirname, basename)
        path = root + '/' + relative_basename

        upload_cache = UploadCache.new(key, path, options)
        params.set(key, upload_cache.io)
        return upload_cache
      end

      nil
    end

    def default_upload_cache_for(params, key, options)
      upload_cache = UploadCache.new(key, options)
      params.set(key, upload_cache.io)
      return upload_cache
    end
  end

  attr_accessor :key
  attr_accessor :cache_key
  attr_accessor :options
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
    @options = Map.options_for!(args)

    @key = key
    @cache_key = UploadCache.cache_key_for(@key)
    @name = UploadCache.name_for(@cache_key)

    path = args.shift || @options[:path]

    default = Map.for(@options[:default])

    @default_url = default[:url] || @options[:default_url] || UploadCache.default.url
    @default_path = default[:path] || @options[:default_path] || UploadCache.default.path

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
      @io.send(:extend, WeakReference)
      @io.upload_cache = self
    end
  end

  module WeakReference
    attr_accessor :upload_cache_object_id

    def upload_cache
      begin
        ObjectSpace._id2ref(upload_cache_object_id)
      rescue Object
        nil
      end
    end

    def upload_cache=(upload_cache)
      self.upload_cache_object_id = upload_cache.object_id
    end
  end

  def inspect
    {
      UploadCache.name =>
        {
          :key => key, :cache_key => key, :name => name, :path => path, :io => io
        }
    }.inspect
  end

  def blank?
    @path.blank?
  end

  def url
    if @value
      File.join(UploadCache.url, @value)
    else
      @default_url ? @default_url : nil
      #defined?(@placeholder) ? @placeholder : nil
    end
  end

  def to_s
    url
  end

  def hidden
    raw("<input type='hidden' name='#{ @name }' value='#{ @value }' class='upload_cache hidden' />") if @value
  end

  def input
    raw("<input type='file' name='#{ @name }' class='upload_cache input' />")
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

  def clear!(&block)
    result = block ? block.call(@path) : nil 

    unless UploadCache.turd?
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

    result
  end
  alias_method('clear', 'clear!')
end

Upload_cache = UploadCache unless defined?(Upload_cache)
