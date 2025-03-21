module ActiveMerchant # :nodoc:
  module Billing # :nodoc:
    class NetworkTokenizationCreditCard < CreditCard
      # A +NetworkTokenizationCreditCard+ object represents a tokenized credit card
      # using the EMV Network Tokenization specification, http://www.emvco.com/specifications.aspx?id=263.
      #
      # It includes all fields of the +CreditCard+ class with additional fields for
      # verification data that must be given to gateways through existing fields (3DS / EMV).
      #
      # The only tested usage of this at the moment is with an Apple Pay decrypted PKPaymentToken,
      # https://developer.apple.com/library/ios/documentation/PassKit/Reference/PaymentTokenJSON/PaymentTokenJSON.html

      # These are not relevant (verification) or optional (name) for Apple Pay
      self.require_verification_value = false
      self.require_name = false

      attr_accessor :payment_cryptogram, :eci, :transaction_id, :metadata, :payment_data
      attr_writer :source

      SOURCES = %i(apple_pay android_pay google_pay network_token)

      def source
        if defined?(@source) && SOURCES.include?(@source)
          @source
        else
          :apple_pay
        end
      end

      def credit_card?
        true
      end

      def network_token?
        source == :network_token
      end

      def mobile_wallet?
        %i[apple_pay android_pay google_pay].include?(source)
      end

      def encrypted_wallet?
        payment_data.present?
      end

      def type
        'network_tokenization'
      end
    end
  end
end
