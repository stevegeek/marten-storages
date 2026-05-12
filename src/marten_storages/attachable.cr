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
  module Attachable
    macro included
      macro attachment_model(klass)
        def attachments_for(name : ::String) : ::Array(\{{ klass.id }})
          \{{ klass.id }}
            .filter(record_type: self.class.name, record_id: pk)
            .filter(name: name)
            .filter(variant_of_id: nil)
            .order(:created_at)
            .to_a
        end

        def attachment_for(name : ::String) : \{{ klass.id }}?
          \{{ klass.id }}
            .filter(record_type: self.class.name, record_id: pk)
            .filter(name: name)
            .filter(variant_of_id: nil)
            .order("-created_at")
            .first
        end

        def variants_of(attachment : \{{ klass.id }}, kind : ::String) : \{{ klass.id }}?
          \{{ klass.id }}
            .filter(variant_of_id: attachment.pk)
            .filter(variation_kind: kind)
            .first
        end
      end
    end
  end
end
