require 'base64'
require 'digest'

module ActiveMerchant # :nodoc:
  module Billing # :nodoc:
    class PaymentezGateway < Gateway # :nodoc:
      version 'v2'

      self.test_url = "https://ccapi-stg.paymentez.com/#{fetch_version}/"
      self.live_url = "https://ccapi.paymentez.com/#{fetch_version}/"

      self.supported_countries = %w[MX EC CO BR CL PE]
      self.default_currency = 'USD'
      self.supported_cardtypes = %i[visa master american_express diners_club elo alia olimpica discover maestro sodexo carnet unionpay jcb]

      self.homepage_url = 'https://secure.paymentez.com/'
      self.display_name = 'Paymentez'

      STANDARD_ERROR_CODE_MAPPING = {
        1 => :processing_error,
        6 => :card_declined,
        9 => :card_declined,
        10 => :processing_error,
        11 => :card_declined,
        12 => :config_error,
        13 => :config_error,
        19 => :invalid_cvc,
        20 => :config_error,
        21 => :card_declined,
        22 => :card_declined,
        23 => :card_declined,
        24 => :card_declined,
        25 => :card_declined,
        26 => :card_declined,
        27 => :card_declined,
        28 => :card_declined
      }.freeze

      SUCCESS_STATUS = ['APPROVED', 'PENDING', 'pending', 'success', 1, 0]

      CARD_MAPPING = {
        'visa' => 'vi',
        'master' => 'mc',
        'american_express' => 'ax',
        'diners_club' => 'di',
        'elo' => 'el',
        'discover' => 'dc',
        'maestro' => 'ms',
        'sodexo' => 'sx',
        'olimpica' => 'ol',
        'carnet' => 'ct',
        'unionpay' => 'up',
        'jcb' => 'jc'
      }.freeze

      def initialize(options = {})
        requires!(options, :application_code, :app_key)
        super
      end

      def purchase(money, payment, options = {})
        post = {}

        add_invoice(post, money, options)
        add_payment(post, payment)
        add_customer_data(post, options)
        add_extra_params(post, options)
        action = payment.is_a?(String) ? 'debit' : 'debit_cc'

        commit_transaction(action, post)
      end

      def authorize(money, payment, options = {})
        return purchase(money, payment, options) if options[:otp_flow]

        post = {}

        add_invoice(post, money, options)
        add_payment(post, payment)
        add_customer_data(post, options)
        add_extra_params(post, options)

        commit_transaction('authorize', post)
      end

      def capture(money, authorization, options = {})
        post = {
          transaction: { id: authorization }
        }
        verify_flow = options[:type] && options[:value]

        if verify_flow
          add_customer_data(post, options)
          add_verify_value(post, options)
        elsif money
          post[:order] = { amount: amount(money).to_f }
        end

        action = verify_flow ? 'verify' : 'capture'
        commit_transaction(action, post)
      end

      def refund(money, authorization, options = {})
        post = { transaction: { id: authorization } }
        post[:order] = { amount: amount(money).to_f } if money
        add_more_info(post, options)

        commit_transaction('refund', post)
      end

      def void(authorization, _options = {})
        post = { transaction: { id: authorization } }
        commit_transaction('refund', post)
      end

      def verify(credit_card, options = {})
        MultiResponse.run do |r|
          r.process { authorize(100, credit_card, options) }
          r.process { void(r.authorization, options) }
        end
      end

      def store(credit_card, options = {})
        post = {}

        add_customer_data(post, options)
        add_payment(post, credit_card)

        response = commit_card('add', post)
        if !response.success? && !(token = extract_previous_card_token(response)).nil?
          unstore(token, options)
          response = commit_card('add', post)
        end
        response
      end

      def unstore(identification, options = {})
        post = { card: { token: identification }, user: { id: options[:user_id] } }
        commit_card('delete', post)
      end

      def inquire(authorization, options = {})
        commit_transaction('inquire', authorization)
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript.
          gsub(%r{(\\?"number\\?":)(\\?"[^"]+\\?")}, '\1[FILTERED]').
          gsub(%r{(\\?"cvc\\?":)(\\?"[^"]+\\?")}, '\1[FILTERED]').
          gsub(%r{(Auth-Token: )([A-Za-z0-9=]+)}, '\1[FILTERED]')
      end

      private

      def add_customer_data(post, options)
        requires!(options, :user_id)
        post[:user] ||= {}
        post[:user][:id] = options[:user_id]
        post[:user][:email] = options[:email] if options[:email]
        post[:user][:ip_address] = options[:ip] if options[:ip]
        post[:user][:fiscal_number] = options[:fiscal_number] if options[:fiscal_number]
        if phone = options[:phone] || options.dig(:billing_address, :phone)
          post[:user][:phone] = phone
        end
      end

      def add_invoice(post, money, options)
        post[:session_id] = options[:session_id] if options[:session_id]

        post[:order] ||= {}
        post[:order][:amount] = amount(money).to_f
        post[:order][:vat] = options[:vat] if options[:vat]
        post[:order][:dev_reference] = options[:dev_reference] if options[:dev_reference]
        post[:order][:description] = options[:description] if options[:description]
        post[:order][:discount] = options[:discount] if options[:discount]
        post[:order][:installments] = options[:installments] if options[:installments]
        post[:order][:installments_type] = options[:installments_type] if options[:installments_type]
        post[:order][:taxable_amount] = options[:taxable_amount] if options[:taxable_amount]
        post[:order][:tax_percentage] = options[:tax_percentage] if options[:tax_percentage]
      end

      def add_payment(post, payment)
        post[:card] ||= {}
        if payment.is_a?(String)
          post[:card][:token] = payment
        else
          post[:card][:number] = payment.number
          post[:card][:holder_name] = payment.name
          post[:card][:expiry_month] = payment.month
          post[:card][:expiry_year] = payment.year
          post[:card][:cvc] = payment.verification_value
          post[:card][:type] = CARD_MAPPING[payment.brand]
        end
      end

      def add_verify_value(post, options)
        post[:type] = options[:type] if options[:type]
        post[:value] = options[:value] if options[:value]
      end

      def add_extra_params(post, options)
        extra_params = {}
        extra_params.merge!(options[:extra_params]) if options[:extra_params]

        add_external_mpi_fields(extra_params, options)

        post['extra_params'] = extra_params unless extra_params.empty?
      end

      def add_external_mpi_fields(extra_params, options)
        three_d_secure_options = options[:three_d_secure]
        return unless three_d_secure_options

        auth_data = {
          cavv: three_d_secure_options[:cavv],
          xid: three_d_secure_options[:xid],
          eci: three_d_secure_options[:eci],
          version: three_d_secure_options[:version],
          reference_id: three_d_secure_options[:ds_transaction_id],
          status: three_d_secure_options[:authentication_response_status] || three_d_secure_options[:directory_response_status]
        }.compact

        return if auth_data.empty?

        extra_params[:auth_data] = auth_data
      end

      def add_more_info(post, options)
        post[:more_info] = options[:more_info] if options[:more_info]
      end

      def parse(body)
        JSON.parse(body)
      end

      def commit_raw(object, action, parameters)
        if action == 'inquire'
          url = "#{test? ? test_url : live_url}#{object}/#{parameters}"
          begin
            raw_response = ssl_get(url, headers)
          rescue ResponseError => e
            raw_response = e.response.body
          end
        else
          url = "#{test? ? test_url : live_url}#{object}/#{action}"
          begin
            raw_response = ssl_post(url, post_data(parameters), headers)
          rescue ResponseError => e
            raw_response = e.response.body
          end
        end

        begin
          parse(raw_response)
        rescue JSON::ParserError
          { 'status' => 'Internal server error' }
        end
      end

      def commit_transaction(action, parameters)
        response = commit_raw('transaction', action, parameters)
        Response.new(
          success_from(response, action),
          message_from(response),
          response,
          authorization: authorization_from(response),
          test: test?,
          error_code: error_code_from(response)
        )
      end

      def commit_card(action, parameters)
        response = commit_raw('card', action, parameters)
        Response.new(
          card_success_from(response),
          card_message_from(response),
          response,
          authorization: card_authorization_from(response),
          test: test?,
          error_code: card_error_code_from(response)
        )
      end

      def headers
        {
          'Auth-Token' => authentication_code,
          'Content-Type' => 'application/json'
        }
      end

      def success_from(response, action = nil)
        transaction_current_status = response.dig('transaction', 'current_status')
        request_status = response['status']
        transaction_status = response.dig('transaction', 'status')
        default_response = SUCCESS_STATUS.include?(transaction_current_status || request_status || transaction_status)

        case action
        when 'refund'
          if transaction_current_status && request_status
            transaction_current_status&.upcase == 'CANCELLED' && request_status&.downcase == 'success'
          else
            default_response
          end
        else
          default_response
        end
      end

      def card_success_from(response)
        return false if response.include?('error')
        return true if response['message'] == 'card deleted'

        response['card']['status'] == 'valid'
      end

      def message_from(response)
        return response['detail'] if response['detail'].present?

        if !success_from(response) && response['error']
          response['error'] && response['error']['type']
        else
          (response['transaction'] && response['transaction']['message']) || (response['message'])
        end
      end

      def card_message_from(response)
        if response.include?('error')
          response['error']['type']
        else
          response['message'] || response['card']['message']
        end
      end

      def authorization_from(response)
        response['transaction'] && response['transaction']['id']
      end

      def card_authorization_from(response)
        response['card'] && response['card']['token']
      end

      def extract_previous_card_token(response)
        match = /Card already added: (\d+)/.match(response.message)
        match && match[1]
      end

      def post_data(parameters = {})
        JSON.dump(parameters)
      end

      def error_code_from(response)
        return if success_from(response)

        if response['transaction']
          detail = response['transaction']['status_detail']
          return STANDARD_ERROR_CODE[STANDARD_ERROR_CODE_MAPPING[detail]] if STANDARD_ERROR_CODE_MAPPING.include?(detail)
        elsif response['error']
          return STANDARD_ERROR_CODE[:config_error]
        end
        STANDARD_ERROR_CODE[:processing_error]
      end

      def card_error_code_from(response)
        STANDARD_ERROR_CODE[:processing_error] unless card_success_from(response)
      end

      def authentication_code
        timestamp = Time.new.to_i
        unique_token = Digest::SHA256.hexdigest("#{@options[:app_key]}#{timestamp}")
        authentication_string = "#{@options[:application_code]};#{timestamp};#{unique_token}"
        Base64.encode64(authentication_string).delete("\n")
      end
    end
  end
end
