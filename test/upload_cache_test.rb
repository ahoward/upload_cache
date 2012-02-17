# -*- encoding : utf-8 -*-
require 'fileutils'
require 'testing'
require 'upload_cache'

Testing UploadCache do

##
#
  testing 'upload_cache will cache an upload and alter params to point to it' do
    uploaded_file = new_uploaded_file

    params = {
      :key => uploaded_file
    }

    upload_cache = assert{ UploadCache.cache(params, :key) }

    assert{ params[:key] }
    assert{ params[:key].respond_to?(:upload_cache_object_id) }
    assert{ params[:key].respond_to?(:upload_cache) }


    assert{ upload_cache.io }
    assert{ upload_cache.path }
    assert{ uploaded_file.read == upload_cache.io.read }
  end

##
#
  testing 'upload_cache looks for previously uploaded files under a special key' do
    uploaded_file_path = previously_uploaded_file_path

    params = {
      :key => nil,
      :key_upload_cache => uploaded_file_path 
    }

    upload_cache = assert{ UploadCache.cache(params, :key) }

    assert{ params[:key] }
    assert{ params[:key].respond_to?(:upload_cache_object_id) }
    assert{ params[:key].respond_to?(:upload_cache) }


    assert{ upload_cache.io }
    assert{ upload_cache.path }
    assert{ IO.read(File.join(Public, uploaded_file_path)) == IO.read(upload_cache.io.path) }
  end

##
#
  testing 'upload_cache will return the same object iff nothing has changed' do
    params = {
      :key => new_uploaded_file
    }

    a = assert{ UploadCache.cache(params, :key) }
    b = assert{ UploadCache.cache(params, :key) }
    assert{ a.object_id == b.object_id }
  end

##
#
  testing 'upload_cache will *not* return the same object iff something has changed' do
    params = {
      :key => new_uploaded_file
    }

    a = assert{ UploadCache.cache(params, :key) }
    b = assert{ UploadCache.cache(params, :key) }
    assert{ a.object_id == b.object_id }

    params[:key] = new_uploaded_file
    c = assert{ UploadCache.cache(params, :key) }
    assert{ a.object_id != c.object_id }
    assert{ b.object_id != c.object_id }
  end


  TestDir                 = File.expand_path(File.dirname(__FILE__))
  Public                  = File.join(TestDir, 'public')
  PublicSystem            = File.join(TestDir, 'public/system')
  PublicSystemUploadCache = File.join(TestDir, 'public/system/upload_cache')
  PublicSystemUploads     = File.join(TestDir, 'public/system/uploads')

  FileUtils.mkdir_p(Public)
  FileUtils.mkdir_p(PublicSystem)
  FileUtils.mkdir_p(PublicSystemUploadCache)
  FileUtils.mkdir_p(PublicSystemUploads)

  setup do
    assert{ UploadCache.root = PublicSystemUploadCache }
  end

  at_exit do
    glob = File.join(PublicSystemUploads, '**/**')
    Dir.glob(glob) do |entry|
      FileUtils.rm_rf(entry)
    end
  end

  Count = '0'
  def new_uploaded_file(&block)
    path = File.join(PublicSystemUploads, Count)
    at_exit{ FileUtils.rm_f(path) }
    fd = open(path, 'w+')
    fd.puts(Count)
    return fd unless block
    begin
      block.call(fd)
    ensure
      fd.close rescue nil
    end
  ensure
    Count.succ!
  end

  def previously_uploaded_file_path
    new_uploaded_file do |uploaded_file|
      basename = File.basename(uploaded_file.path)
      uuid = assert{ UploadCache.uuid }
      dst = File.join(PublicSystemUploadCache, uuid, basename)
      FileUtils.mkdir(File.dirname(dst))
      open(dst, 'w') do |fd|
        fd.write(uploaded_file.read)
      end
      "/system/upload_cache/#{ uuid }/#{ basename }"
    end
  end
end






BEGIN {
  testdir = File.dirname(File.expand_path(__FILE__))
  testlibdir = File.join(testdir, 'lib')
  rootdir = File.dirname(testdir)
  libdir = File.join(rootdir, 'lib')
  $LOAD_PATH.push(libdir)
  $LOAD_PATH.push(testlibdir)
}
