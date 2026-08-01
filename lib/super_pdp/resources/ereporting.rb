# frozen_string_literal: true

module SuperPdp
  module Resources
    # E-reporting endpoints.
    #
    # You push B2C transactions and B2C payments; SUPER PDP aggregates them and
    # transmits the declarations to the PPF on a schedule that depends on the
    # company VAT regime (see Companies#update_vat_regime). The `ereportings`
    # endpoints expose the aggregated declarations actually sent, with status tracking.
    #
    # NOTE: the request envelope for the create endpoints is inferred from the API's
    # list envelope ({ "data" => [...] }). If SUPER PDP expects a bare array, pass one
    # explicitly — both shapes are forwarded as-is.
    class Ereporting < Base
      # --- B2C transactions ---------------------------------------------------

      # POST /v1.beta/b2c_transactions
      # Accepts an Array of transaction hashes (wrapped as {data: [...]}) or a raw Hash.
      def create_transactions(transactions)
        body = transactions.is_a?(Array) ? { data: transactions } : transactions
        connection.post_json("b2c_transactions", body)
      end

      # GET /v1.beta/b2c_transactions
      def transactions(starting_after_id: nil, ending_before_id: nil, order: nil, limit: nil)
        body = connection.get("b2c_transactions",
                              { starting_after_id: starting_after_id,
                                ending_before_id: ending_before_id,
                                order: order, limit: limit })
        build_collection(body, Models::B2cTransaction)
      end

      # --- B2C payments -------------------------------------------------------

      # POST /v1.beta/b2c_payments
      def create_payments(payments)
        body = payments.is_a?(Array) ? { data: payments } : payments
        connection.post_json("b2c_payments", body)
      end

      # GET /v1.beta/b2c_payments
      def payments(starting_after_id: nil, ending_before_id: nil, order: nil, limit: nil)
        body = connection.get("b2c_payments",
                              { starting_after_id: starting_after_id,
                                ending_before_id: ending_before_id,
                                order: order, limit: limit })
        build_collection(body, Models::B2cPayment)
      end

      # --- Aggregated declarations sent to the PPF ----------------------------

      # GET /v1.beta/ereportings
      def list(role_code: nil, order: nil, starting_after_id: nil, ending_before_id: nil, limit: nil)
        body = connection.get("ereportings",
                              { role_code: role_code, order: order,
                                starting_after_id: starting_after_id,
                                ending_before_id: ending_before_id, limit: limit })
        build_collection(body, Models::Ereporting)
      end

      # GET /v1.beta/ereportings/preview — preview data not yet transmitted.
      # kind: "transaction" | "payment". role_code: "BY" | "SE".
      def preview(date:, kind:, role_code:)
        connection.get("ereportings/preview", { date: date, kind: kind, role_code: role_code })
      end

      # GET /v1.beta/ereportings/{id}
      def get(id, format: nil)
        body = connection.get("ereportings/#{id}", { format: format })
        body.is_a?(Hash) ? build(body, Models::Ereporting) : body
      end
    end
  end
end
