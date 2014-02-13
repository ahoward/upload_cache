## upload_cache.gemspec
#

Gem::Specification::new do |spec|
  spec.name = "upload_cache"
  spec.version = "2.2.0"
  spec.platform = Gem::Platform::RUBY
  spec.summary = "upload_cache"
  spec.description = " a small utility library to facility caching http file uploads between form validation failures.  designed for rails, but usable anywhere."

  spec.files =
["README",
 "Rakefile",
 "lib",
 "lib/upload_cache.rb",
 "test",
 "test/lib",
 "test/lib/testing.rb",
 "test/upload_cache_test.rb",
 "upload_cache.gemspec"]

  spec.executables = []
  
  spec.require_path = "lib"

  spec.test_files = nil

  

  spec.extensions.push(*[])

  spec.rubyforge_project = "codeforpeople"
  spec.author = "Ara T. Howard"
  spec.email = "ara.t.howard@gmail.com"
  spec.homepage = "https://github.com/ahoward/upload_cache"
end
