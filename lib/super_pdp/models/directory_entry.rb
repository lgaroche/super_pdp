# frozen_string_literal: true

module SuperPdp
  module Models
    # An entry in the directory ("ligne d'annuaire") used for routing invoices.
    class DirectoryEntry < Base
      def identifier
        self["identifier"]
      end

      def directory
        self["directory"]
      end

      def status
        self["status"]
      end

      # "Reply-to" technical addresses used to receive over the Peppol network.
      def reply_to?
        self["is_replyto"] ? true : false
      end

      def company
        raw = self["company"]
        raw.is_a?(Hash) ? Company.new(raw) : raw
      end
    end
  end
end
