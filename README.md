# marten_storages

A Crystal shard for [Marten](https://martenframework.com) that ports
Rails Writebook's Active Storage analog — the blob + attachment +
variant pipeline — to Marten.

Rails Writebook builds on Active Storage and patches it via
`lib/rails_ext/active_storage_sluggable.rb`. Marten ships only the
low-level `:file` / `:image` fields with no equivalent for
`has_one_attached` / `has_many_attached`, polymorphic attachment
tables, or named on-disk variants. This shard fills that gap.

## Installation

```yaml
dependencies:
  marten_storages:
    github: stevegeek/marten-storages
```

Then `shards install`.

The shard depends on [`crystal-vips`](https://github.com/naqvis/crystal-vips)
for image resizing — make sure `libvips` is available on your system
(`brew install vips` on macOS).

## Usage

### 1. Define a concrete Attachment row model in your app

Marten's polymorphic `to:` list is compile-time fixed, so the shard
can't ship a usable polymorphic table — your app owns it. The model
must declare these fields exactly (names matter; the shard's
`Service` queries them):

```crystal
class Attachment < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :record, :polymorphic, to: [Book, Picture, Markdown], related: :attachments
  field :name, :string, max_size: 64, blank: false, null: false
  field :file, :file, blank: false, null: false, upload_to: "attachments"
  field :variant_of, :many_to_one, to: Attachment, related: :variants, blank: true, null: true, on_delete: :cascade
  field :variation_kind, :string, max_size: 64, blank: true, null: true
  field :content_type, :string, max_size: 128, blank: true, null: true
  field :byte_size, :big_int, blank: true, null: true

  with_timestamp_fields
end
```

### 2. Mix `Attachable` into each target model

```crystal
class Book < Marten::Model
  include MartenStorages::Attachable

  field :id, :big_int, primary_key: true, auto: true
  field :title, :string

  attachment_model ::Attachment
end
```

This adds `attachment_for(name)`, `attachments_for(name)` and
`variants_of(attachment, kind)` instance methods.

### 3. Attach files via `Service`

```crystal
# Basic attach (pass the form part's Content-Type so it's persisted
# on the row — `content_type:` defaults to nil for back-compat):
MartenStorages::Service.attach(
  model: ::Attachment,
  record: book,
  name: "cover",
  uploaded_file: uploaded,
  content_type: "image/jpeg",
)

# Attach + generate variants in one call (libvips resize). The
# variants hash accepts either the legacy NamedTuple shape or the
# Struct form (`MartenStorages::VariantPipeline::Spec.new(...)`),
# which also supports a per-variant `format:` override:
MartenStorages::Service.attach(
  model: ::Attachment,
  record: picture,
  name: "image",
  uploaded_file: uploaded,
  variants: {
    "large" => MartenStorages::VariantPipeline::Spec.new(max_dimension: 1500),
    "icon"  => MartenStorages::VariantPipeline::Spec.new(max_dimension: 64, format: "png"),
  },
)

# Lookups:
cover = MartenStorages::Service.find_one(model: ::Attachment, record: book, name: "cover")
thumb = MartenStorages::Service.variant_of(model: ::Attachment, original: cover, kind: "thumbnail")
```

### 4. (Optional) Configure shared variant kinds

```crystal
MartenStorages.configure do |c|
  c.default_variant_format = "jpg"
  c.register_variant("thumbnail", max_dimension: 600)
  c.register_variant("large", max_dimension: 1500)
end
```

The registry is sugar — `Service.attach` always accepts inline
`variants:` hashes too.

## Why a shard?

Rails Writebook builds on Active Storage and patches it via
`active_storage_sluggable.rb`. The Marten port keeps the same
shape — single polymorphic Attachment table + pre-computed variant
rows — but lives in its own shard because:

- Marten has no built-in blob/attachment indirection to patch onto.
- The polymorphic `to:` list must be compile-time fixed and host-owned.
- Variant generation via libvips is general-purpose and worth reusing
  across any Marten app needing image attachments.

## Development

```sh
shards install
script/cr spec/   # or `crystal spec`
```

## License

MIT — see `LICENSE`.
