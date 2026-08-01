# frozen_string_literal: true

module SuperPdp
  module Resources
    # Directory endpoints: the official French directory lookup (read-only) and
    # your own directory entries ("lignes d'annuaire") used for routing.
    class Directory < Base
      # GET /v1.beta/french_directory/companies — search the official French directory.
      def search_companies(formal_name_starts_with: nil, post_code_starts_with: nil,
                           number: nil, limit: nil)
        body = connection.get("french_directory/companies",
                              { formal_name_starts_with: formal_name_starts_with,
                                post_code_starts_with: post_code_starts_with,
                                number: number,
                                limit: limit })
        build_collection(body, Models::Company)
      end

      # GET /v1.beta/french_directory/entries — directory entries for a SIREN/SIRET.
      def french_entries(number:)
        body = connection.get("french_directory/entries", { number: number })
        build_collection(body, Models::DirectoryEntry)
      end

      # GET /v1.beta/directory_entries — your own directory entries.
      def list
        build_collection(connection.get("directory_entries"), Models::DirectoryEntry)
      end

      # GET /v1.beta/directory_entries/{id}
      def get(id)
        build(connection.get("directory_entries/#{id}"), Models::DirectoryEntry)
      end

      # POST /v1.beta/directory_entries — register a routing entry.
      # Required: directory + identifier.
      def create(directory:, identifier:, **extra)
        body = { directory: directory, identifier: identifier }.merge(extra)
        build(connection.post_json("directory_entries", body), Models::DirectoryEntry)
      end

      # DELETE /v1.beta/directory_entries/{id}
      def delete(id)
        connection.delete("directory_entries/#{id}")
        true
      end
    end
  end
end
