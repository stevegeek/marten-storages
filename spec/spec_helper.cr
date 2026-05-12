ENV["MARTEN_ENV"] = "test"

require "spec"
require "sqlite3"
require "../src/marten_storages"
require "marten/spec"

require "./test_project/app"
require "./test_project/models/**"

# Per-spec scratch dir for media uploads. Cleaned out before each test
# so attachment file paths don't collide across runs.
MEDIA_ROOT = Path["./tmp/marten_storages_spec_media"].expand.to_s

Marten.configure :test do |config|
  config.secret_key = "__insecure_spec_secret_#{Random::Secure.random_bytes(16).hexstring}__"
  config.log_level = ::Log::Severity::None

  config.installed_apps = [MartenStoragesSpecApp]

  config.database do |db|
    db.backend = :sqlite
    db.name = ":memory:"
  end

  config.media_files.root = MEDIA_ROOT
  config.media_files.url = "/media/"
end

Spec.before_each do
  MartenStorages.reset_configuration!
  ::FileUtils.rm_rf(MEDIA_ROOT)
  ::Dir.mkdir_p(MEDIA_ROOT)
end

# Helpers for building a Marten::HTTP::UploadedFile from a path on disk —
# mirrors the seed_manual / handler call shape.
module SpecHelpers
  extend self

  # Build an Marten::HTTP::UploadedFile from a path on disk; yields it to
  # the block so the underlying File handle stays open until the upload
  # is consumed.
  def uploaded_file(path : String, content_type : String = "image/jpeg", & : ::Marten::HTTP::UploadedFile -> _)
    filename = ::File.basename(path)
    content_disposition = "form-data; name=\"file\"; filename=\"#{filename}\""
    headers = ::HTTP::Headers{
      "Content-Disposition" => content_disposition,
      "Content-Type"        => content_type,
    }
    ::File.open(path, "rb") do |io|
      part = ::HTTP::FormData::Part.new(headers: headers, body: io)
      uploaded = ::Marten::HTTP::UploadedFile.new(part)
      yield uploaded
    end
  end

  # Generate a small JPEG on disk via vips (so we know it's a valid image
  # and roughly 800x600). Returns the absolute path.
  def make_test_jpeg(filename : String = "sample.jpg", width : Int32 = 800, height : Int32 = 600) : String
    path = ::File.join(::Dir.tempdir, filename)
    # Black-and-white image, sized to make the variant pipeline have
    # work to do (max_dimension=200 will scale).
    image = ::Vips::Image.black(width, height)
    image.write_to_file(path)
    path
  end
end
