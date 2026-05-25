module MartenStorages
  # Mixin for host *target* models — the records that own attachments
  # (Book/Picture/Markdown in Writebook). Adds query sugar for fetching
  # attachments on the calling record. The actual attach/save logic
  # lives in `Service`.
  #
  # Usage:
  #
  #   class Book < Marten::Model
  #     include MartenStorages::Attachable
  #
  #     # ...other fields...
  #
  #     # Tell the mixin which concrete Attachment model class to query.
  #     attachment_model ::DocumentAttachment
  #   end
  #
  # Adds:
  #   - `book.attachments_for("cover")` — Array(Attachment) for all originals
  #     of this name (ordered by `created_at` asc).
  #   - `book.attachment_for("cover")` — most-recent original (or nil).
  #   - `book.variants_of(attachment, "thumbnail")` — variant row for the
  #     given original + variation_kind (or nil).
  #
  # `attachment_model` is a class-level keyword that captures the host's
  # concrete polymorphic Attachment class. Marten's polymorphic `to:`
  # list is compile-time fixed, so the *host app* owns the concrete
  # Attachment model with its own `to: [...]` list — the shard just
  # threads queries through whatever class the host names.
  #
  # The generated methods delegate to `MartenStorages::Service` so the
  # query shape lives in one place (review §10 / §11) — extending the
  # filter chain (e.g. soft-delete) happens in `Service` and the mixin
  # picks it up for free.
  module Attachable
    macro included
      macro attachment_model(klass)
        # Compile-time guard (review §12): the macro receives a bare
        # class name; if the host already loaded the referenced class
        # (`resolve?` succeeds), assert it's a Marten::DB::Model
        # subclass so a typo or non-Model class fails at compile time
        # instead of at the first `filter(...)` runtime call. When the
        # class isn't yet loaded (forward reference — common with
        # polymorphic Attachment classes that load *after* their
        # targets) we let it slide; the generated `\{{ klass.id }}`
        # invocations will catch a real typo at call-method
        # type-checking time.
        \{% if (resolved = klass.resolve?) %}
          \{% unless resolved <= ::Marten::DB::Model %}
            \{% raise "attachment_model expected a Marten::DB::Model subclass, got: #{resolved} (#{resolved.class})" %}
          \{% end %}
        \{% end %}

        def attachments_for(name : ::String) : ::Array(\{{ klass.id }})
          ::MartenStorages::Service.find_many(model: \{{ klass.id }}, record: self, name: name)
        end

        def attachment_for(name : ::String) : \{{ klass.id }}?
          ::MartenStorages::Service.find_one(model: \{{ klass.id }}, record: self, name: name)
        end

        def variants_of(attachment : \{{ klass.id }}, kind : ::String) : \{{ klass.id }}?
          ::MartenStorages::Service.variant_of(model: \{{ klass.id }}, original: attachment, kind: kind)
        end
      end
    end
  end
end
