require 'test_helper'
require 'yaml'

class PayeezyGateway < Test::Unit::TestCase
  include CommStub

  def setup
    @gateway = PayeezyGateway.new(fixtures(:payeezy))

    @credit_card = credit_card
    @bad_credit_card = credit_card('4111111111111113')
    @check = check
    @amount = 100
    @options = {
      billing_address: address,
      ta_token: '123'
    }
    @options_stored_credentials = {
      cardbrand_original_transaction_id: 'original_transaction_id_abc123',
      sequence: 'FIRST',
      is_scheduled: true,
      initiator: 'MERCHANT',
      auth_type_override: 'A'
    }
    @options_standardized_stored_credentials = {
      stored_credential: {
        network_transaction_id: 'stored_credential_abc123',
        initial_transaction: false,
        reason_type: 'recurring',
        initiator: 'cardholder'
      }
    }
    @authorization = 'ET1700|106625152|credit_card|4738'
    @reversal_id = SecureRandom.random_number(1000000).to_s

    @options_mdd = {
      soft_descriptors: {
        dba_name: 'Caddyshack',
        street: '1234 Any Street',
        city: 'Durham',
        region: 'North Carolina',
        mid: 'mid_1234',
        mcc: 'mcc_5678',
        postal_code: '27701',
        country_code: 'US',
        merchant_contact_info: '8885551212'
      }
    }
    @apple_pay_card = network_tokenization_credit_card(
      '4761209980011439',
      payment_cryptogram: 'YwAAAAAABaYcCMX/OhNRQAAAAAA=',
      month: '11',
      year: '2022',
      eci: 5,
      source: :apple_pay,
      verification_value: 569
    )
    @apple_pay_card_amex = network_tokenization_credit_card(
      '373953192351004',
      brand: 'american_express',
      payment_cryptogram: 'YwAAAAAABaYcCMX/OhNRQAAAAAA=',
      month: '11',
      year: Time.now.year + 1,
      eci: 5,
      source: :apple_pay,
      verification_value: 569
    )
  end

  def test_invalid_credentials
    @gateway.expects(:ssl_post).raises(bad_credentials_response)

    assert response = @gateway.authorize(100, @credit_card, {})
    assert_failure response
    assert response.test?
    assert response.authorization
    assert_equal 'HMAC validation Failure', response.message
  end

  def test_invalid_token
    @gateway.expects(:ssl_post).raises(invalid_token_response)

    assert response = @gateway.authorize(100, @credit_card, {})
    assert_failure response
    assert response.test?
    assert response.authorization
    assert_equal 'Access denied', response.message
  end

  def test_invalid_token_on_integration
    @gateway.expects(:ssl_post).raises(invalid_token_response_integration)

    assert response = @gateway.authorize(100, @credit_card, {})
    assert_failure response
    assert response.test?
    assert response.authorization
    assert_equal 'Invalid ApiKey for given resource', response.message
  end

  def test_successful_purchase
    @credit_card.first_name = nil
    @credit_card.last_name = nil

    response = stub_comms do
      @gateway.purchase(@amount, @credit_card, @options)
    end.check_request do |_endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal 'Jim Smith', request.dig('credit_card', 'cardholder_name')
    end.respond_with(successful_purchase_response)
    assert_success response
    assert_equal 'ET114541|55083431|credit_card|1', response.authorization
    assert response.test?
    assert_equal 'Transaction Normal - Approved', response.message
  end

  def test_successful_purchase_with_apple_pay
    stub_comms do
      @gateway.purchase(@amount, @apple_pay_card, @options)
    end.check_request do |_endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal request['method'], '3DS'
      assert_equal request['3DS']['type'], 'D'
      assert_equal request['3DS']['wallet_provider_id'], 'APPLE_PAY'
    end.respond_with(successful_purchase_response)
  end

  def test_successful_purchase_with_apple_pay_no_cryptogram
    @apple_pay_card.payment_cryptogram = ''
    @apple_pay_card.eci = nil
    stub_comms do
      @gateway.purchase(@amount, @apple_pay_card, @options)
    end.check_request do |_endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal request['eci_indicator'], '5'
      assert_nil request['3DS']['xid']
      assert_nil request['3DS']['cavv']
    end.respond_with(successful_purchase_response)
  end

  def test_successful_purchase_with_apple_pay_amex
    stub_comms do
      @gateway.purchase(@amount, @apple_pay_card_amex, @options)
    end.check_request do |_endpoint, data, _headers|
      request = JSON.parse(data)
      assert request['3DS']['cavv'], @apple_pay_card_amex.payment_cryptogram
      assert_nil request['3DS']['xid']
    end.respond_with(successful_purchase_response)
  end

  def test_failed_purchase_no_name
    @apple_pay_card.first_name = nil
    @apple_pay_card.last_name = nil
    @options[:billing_address] = nil
    stub_comms do
      @gateway.purchase(@amount, @apple_pay_card, @options)
    end.check_request do |_endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal nil, request['cardholder_name']
    end.respond_with(failed_purchase_no_name_response)
  end

  def test_successful_store
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.store(@credit_card, @options.merge(js_security_key: 'js-f4c4b54f08d6c44c8cad3ea80bbf92c4f4c4b54f08d6c44c'))
    end.respond_with(successful_store_response)

    assert_success response
    assert_equal 'Token successfully created.', response.message
    assert response.test?
  end

  def test_successful_store_and_purchase
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.store(@credit_card, @options.merge(js_security_key: 'js-f4c4b54f08d6c44c8cad3ea80bbf92c4f4c4b54f08d6c44c'))
    end.respond_with(successful_store_response)

    assert_success response
    assert_match %r{Token successfully created}, response.message

    @gateway.expects(:ssl_post).returns(successful_purchase_response)

    purchase = @gateway.purchase(@amount, response.authorization, @options)
    assert_success purchase
  end

  def test_failed_store
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.store(@bad_credit_card, @options.merge(js_security_key: 'js-f4c4b54f08d6c44c8cad3ea80bbf92c4f4c4b54f08d6c44c'))
    end.respond_with(failed_store_response)

    assert_failure response
    assert_equal 'The credit card number check failed', response.message
    assert response.test?
  end

  def test_successful_purchase_with_echeck
    @gateway.expects(:ssl_post).returns(successful_purchase_echeck_response)
    assert response = @gateway.purchase(@amount, @check, @options)
    assert_success response
    assert_equal 'ET133078|69864362|tele_check|100', response.authorization
    assert response.test?
    assert_equal 'Transaction Normal - Approved', response.message
  end

  def test_successful_purchase_defaulting_check_number
    check_without_number = check(number: nil)

    response = stub_comms do
      @gateway.purchase(@amount, check_without_number, @options)
    end.check_request do |_endpoint, data, _headers|
      assert_match(/001/, data)
    end.respond_with(successful_purchase_echeck_response)

    assert_success response
    assert_equal 'ET133078|69864362|tele_check|100', response.authorization
    assert response.test?
    assert_equal 'Transaction Normal - Approved', response.message
  end

  def test_successful_purchase_with_customer_ref
    options = @options.merge(level2: { customer_ref: 'An important customer' })
    response = stub_comms do
      @gateway.purchase(@amount, @credit_card, options)
    end.check_request do |_endpoint, data, _headers|
      assert_match(/"level2":{"customer_ref":"An important customer"}/, data)
    end.respond_with(successful_purchase_response)

    assert_success response
  end

  def test_successful_purchase_with_customer_ref_top_level
    options = @options.merge(customer_ref: 'abcde')
    response = stub_comms do
      @gateway.purchase(@amount, @credit_card, options)
    end.check_request do |_endpoint, data, _headers|
      assert_match(/"customer_ref":"abcde"/, data)
    end.respond_with(successful_purchase_response)

    assert_success response
  end

  def test_successful_purchase_with_reference_3
    options = @options.merge(reference_3: '12345')
    response = stub_comms do
      @gateway.purchase(@amount, @credit_card, options)
    end.check_request do |_endpoint, data, _headers|
      assert_match(/"reference_3":"12345"/, data)
    end.respond_with(successful_purchase_response)

    assert_success response
  end

  def test_successful_purchase_with_stored_credentials
    response = stub_comms do
      @gateway.purchase(@amount, @credit_card, @options.merge(@options_stored_credentials))
    end.check_request do |_endpoint, data, _headers|
      stored_credentials = JSON.parse(data)['stored_credentials']['cardbrand_original_transaction_id']
      assert_equal stored_credentials, 'original_transaction_id_abc123'
    end.respond_with(successful_purchase_stored_credentials_response)

    assert_success response
    assert response.test?
    assert_equal 'Transaction Normal - Approved', response.message
  end

  def test_successful_purchase_with_standardized_stored_credentials
    response = stub_comms do
      @gateway.purchase(@amount, @credit_card, @options.merge(@options_standardized_stored_credentials))
    end.check_request do |_endpoint, data, _headers|
      stored_credentials = JSON.parse(data)['stored_credentials']['cardbrand_original_transaction_id']
      assert_equal stored_credentials, 'stored_credential_abc123'
    end.respond_with(successful_purchase_stored_credentials_response)

    assert_success response
    assert response.test?
    assert_equal 'Transaction Normal - Approved', response.message
  end

  def test_successful_purchase_with__stored_credential_and_cardbrand_original_transaction_id
    options = @options_standardized_stored_credentials.merge!(cardbrand_original_transaction_id: 'original_transaction_id_abc123')

    response = stub_comms do
      @gateway.purchase(@amount, @credit_card, @options.merge(options))
    end.check_request do |_endpoint, data, _headers|
      stored_credentials = JSON.parse(data)['stored_credentials']['cardbrand_original_transaction_id']
      assert_equal stored_credentials, 'original_transaction_id_abc123'
    end.respond_with(successful_purchase_stored_credentials_response)

    assert_success response
    assert response.test?
    assert_equal 'Transaction Normal - Approved', response.message
  end

  def test_successful_purchase_with_no_ntid
    @options_standardized_stored_credentials[:stored_credential].delete(:network_transaction_id)

    response = stub_comms do
      @gateway.purchase(@amount, @credit_card, @options.merge(@options_standardized_stored_credentials))
    end.check_request do |_endpoint, data, _headers|
      stored_credentials = JSON.parse(data)['stored_credentials']
      assert_equal stored_credentials.include?(:cardbrand_original_transaction_id), false
    end.respond_with(successful_purchase_stored_credentials_response)

    assert_success response
    assert response.test?
    assert_equal 'Transaction Normal - Approved', response.message
  end

  def test_failed_purchase
    @gateway.expects(:ssl_post).raises(failed_purchase_response)
    assert response = @gateway.purchase(@amount, @credit_card, @options)
    assert_instance_of Response, response
    assert_failure response
    assert_equal response.error_code, 'card_expired'
  end

  def test_failed_purchase_with_insufficient_funds
    response = stub_comms do
      @gateway.purchase(530200, @credit_card, @options)
    end.respond_with(failed_purchase_response_for_insufficient_funds)

    assert_failure response
    assert_equal '302', response.error_code
  end

  def test_successful_authorize
    @gateway.expects(:ssl_post).returns(successful_authorize_response)
    assert response = @gateway.authorize(@amount, @credit_card, @options)
    assert_success response
    assert_equal 'ET156862|69601979|credit_card|100', response.authorization
    assert response.test?
    assert_equal 'Transaction Normal - Approved', response.message
  end

  def test_failed_authorize
    @gateway.expects(:ssl_post).returns(failed_authorize_response)
    assert response = @gateway.authorize(@amount, @credit_card, @options)
    assert_instance_of Response, response
    assert_failure response
  end

  def test_successful_capture
    @gateway.expects(:ssl_post).returns(successful_capture_response)
    assert response = @gateway.capture(@amount, 'ET156862|69601979|credit_card|100')
    assert_success response
    assert_equal 'ET176427|69601874|credit_card|100', response.authorization
    assert response.test?
    assert_equal 'Transaction Normal - Approved', response.message
  end

  def test_successful_authorize_and_capture
    @gateway.expects(:ssl_post).returns(authorize_with_extra_space_in_transaction_id)
    transaction_id = JSON.parse(authorize_with_extra_space_in_transaction_id)['transaction_id']

    assert_equal transaction_id[/\s/], ' '

    assert authorize = @gateway.authorize(@amount, @credit_card, @options)
    assert_success authorize
    assert_equal 'ET176427|69601874|credit_card|100', authorize.authorization
    assert_not_equal authorize.authorization.split('|').first, transaction_id
    assert_equal authorize.authorization.split('|').first, transaction_id.delete(' ')

    @gateway.expects(:ssl_post).returns(successful_capture_response)
    assert capture = @gateway.capture(@amount, authorize.authorization)
    assert_success capture
    assert_equal 'ET176427|69601874|credit_card|100', capture.authorization
    assert_equal 'Transaction Normal - Approved', capture.message
  end

  def test_failed_capture
    @gateway.expects(:ssl_post).raises(failed_capture_response)
    assert response = @gateway.capture(@amount, '')
    assert_instance_of Response, response
    assert_failure response
  end

  def test_successful_refund
    @gateway.expects(:ssl_post).returns(successful_refund_response)
    assert response = @gateway.refund(@amount, @authorization)
    assert_success response
  end

  def test_successful_refund_with_echeck
    @gateway.expects(:ssl_post).returns(successful_refund_echeck_response)
    assert response = @gateway.refund(@amount, @authorization)
    assert_success response
  end

  def test_successful_refund_with_soft_descriptors
    response = stub_comms do
      @gateway.refund(@amount, @authorization, @options.merge(@options_mdd))
    end.check_request do |_endpoint, data, _headers|
      json = '{"transaction_type":"refund","method":"credit_card","transaction_tag":"106625152","currency_code":"USD","amount":"100","soft_descriptors":{"dba_name":"Caddyshack","street":"1234 Any Street","city":"Durham","region":"North Carolina","mid":"mid_1234","mcc":"mcc_5678","postal_code":"27701","country_code":"US","merchant_contact_info":"8885551212"},"merchant_ref":null}'
      assert_match json, data
    end.respond_with(successful_refund_response)

    assert_success response
  end

  def test_successful_refund_with_order_id
    response = stub_comms do
      @gateway.refund(@amount, @authorization, @options.merge(order_id: 1234))
    end.check_request do |_endpoint, data, _headers|
      json = '{"transaction_type":"refund","method":"credit_card","transaction_tag":"106625152","currency_code":"USD","amount":"100","merchant_ref":1234}'
      assert_match json, data
    end.respond_with(successful_refund_response)

    assert_success response
  end

  def test_failed_refund
    @gateway.expects(:ssl_post).raises(failed_refund_response)
    assert response = @gateway.refund(@amount, @authorization)
    assert_failure response
  end

  def test_successful_general_credit
    @gateway.expects(:ssl_post).returns(successful_refund_response)
    assert response = @gateway.credit(@amount, @credit_card)
    assert_success response
  end

  def test_successful_general_credit_with_soft_descriptors
    response = stub_comms do
      @gateway.credit(@amount, @credit_card, @options.merge(@options_mdd))
    end.check_request do |_endpoint, data, _headers|
      soft_descriptors_regex = %r("soft_descriptors":{"dba_name":"Caddyshack","street":"1234 Any Street","city":"Durham","region":"North Carolina","mid":"mid_1234","mcc":"mcc_5678","postal_code":"27701","country_code":"US","merchant_contact_info":"8885551212"})
      assert_match soft_descriptors_regex, data
    end.respond_with(successful_refund_response)

    assert_success response
  end

  def test_successful_general_credit_with_order_id
    response = stub_comms do
      @gateway.credit(@amount, @credit_card, @options.merge(order_id: 1234))
    end.check_request do |_endpoint, data, _headers|
      assert_match(/\"merchant_ref\":1234/, data)
    end.respond_with(successful_refund_response)

    assert_success response
  end

  def test_successful_void
    response = stub_comms do
      @gateway.void(@authorization, @options)
    end.check_request do |_endpoint, data, _headers|
      json = '{"transaction_type":"void","method":"credit_card","transaction_tag":"106625152","currency_code":"USD","amount":"4738"}'
      assert_match json, data
    end.respond_with(successful_void_response)

    assert_success response
  end

  def test_successful_void_with_reversal_id
    stub_comms do
      @gateway.void(@authorization, @options.merge(reversal_id: @reversal_id))
    end.check_request do |_endpoint, data, _headers|
      json = "{\"transaction_type\":\"void\",\"method\":\"credit_card\",\"reversal_id\":\"#{@reversal_id}\",\"currency_code\":\"USD\",\"amount\":\"4738\"}"
      assert_match json, data
    end.respond_with(successful_void_response)
  end

  def test_failed_void
    @gateway.expects(:ssl_post).raises(failed_void_response)
    assert response = @gateway.void(@authorization, @options)
    assert_failure response
  end

  def test_successful_verify
    @gateway.expects(:ssl_post).times(2).returns(successful_authorize_response, successful_void_response)

    response = @gateway.verify(@credit_card, @options)
    assert_success response
  end

  def test_failed_verify
    @gateway.expects(:ssl_post).returns(failed_authorize_response)

    response = @gateway.verify(@credit_card, @options)
    assert_failure response
  end

  def test_invalid_transaction_tag
    @gateway.expects(:ssl_post).raises(failed_capture_response)

    assert response = @gateway.capture(@amount, @authorization)
    assert_instance_of Response, response
    assert_failure response
    error_msg = response.params['Error']['messages']
    error_code = error_msg.map { |x| x.values[0] }
    assert_equal error_code[0], 'server_error'
    assert_equal response.message, 'ProcessedBad Request (69) - Invalid Transaction Tag'
  end

  def test_supported_countries
    assert_equal %w[CA US].sort, PayeezyGateway.supported_countries.sort
  end

  def test_supported_cardtypes
    assert_equal %i[visa master american_express discover jcb diners_club], PayeezyGateway.supported_cardtypes
  end

  def test_avs_result
    @gateway.expects(:ssl_post).returns(successful_purchase_response)

    response = @gateway.purchase(@amount, @credit_card)
    assert_equal '4', response.avs_result['code']
  end

  def test_cvv_result
    @gateway.expects(:ssl_post).returns(successful_void_response)

    response = @gateway.purchase(@amount, @credit_card)
    assert_equal 'I', response.cvv_result['code']
  end

  def test_requests_include_verification_string
    stub_comms do
      @gateway.purchase(@amount, @credit_card, @options)
    end.check_request do |_endpoint, data, _headers|
      json_address = '{"street":"456 My Street","city":"Ottawa","state_province":"ON","zip_postal_code":"K1C2N6","country":"CA"}'
      assert_match json_address, data
    end.respond_with(successful_purchase_response)
  end

  def test_gateway_message_surfaces
    @gateway.expects(:ssl_post).returns(below_minimum_response)
    assert response = @gateway.authorize(@amount, @credit_card, @options)
    assert_failure response
    assert_equal 'Below Minimum Sale', response.message
  end

  def test_card_type
    assert_equal 'Visa', PayeezyGateway::CREDIT_CARD_BRAND['visa']
    assert_equal 'Mastercard', PayeezyGateway::CREDIT_CARD_BRAND['master']
    assert_equal 'American Express', PayeezyGateway::CREDIT_CARD_BRAND['american_express']
    assert_equal 'JCB', PayeezyGateway::CREDIT_CARD_BRAND['jcb']
    assert_equal 'Discover', PayeezyGateway::CREDIT_CARD_BRAND['discover']
  end

  def test_scrub
    assert @gateway.supports_scrubbing?
    assert_equal @gateway.scrub(pre_scrubbed), post_scrubbed
  end

  def test_scrub_store
    assert_equal @gateway.scrub(pre_scrubbed_store), post_scrubbed_store
  end

  def test_scrub_echeck
    assert @gateway.supports_scrubbing?
    assert_equal @gateway.scrub(pre_scrubbed_echeck), post_scrubbed_echeck
  end

  def test_scrub_network_token
    assert_equal @gateway.scrub(pre_scrubbed_network_token), post_scrubbed_network_token
  end

  def test_url
    assert_equal 'https://api.payeezy.com/v1', @gateway.live_url
    assert_equal 'https://api-cert.payeezy.com/v1', @gateway.test_url
    assert_equal 'https://api-cat.payeezy.com/v1', @gateway.integration_url
  end

  private

  def pre_scrubbed
    <<~TRANSCRIPT
      opening connection to api-cert.payeezy.com:443...
      opened
      starting SSL for api-cert.payeezy.com:443...
        SSL established
      <- "POST /v1/transactions HTTP/1.1\r\nContent-Type: application/json\r\nApikey: oKB61AAxbN3xwC6gVAH3dp58FmioHSAT\r\nToken: fdoa-a480ce8951daa73262734cf102641994c1e55e7cdf4c02b6\r\nNonce: 5803993876.636232\r\nTimestamp: 1449523748359\r\nAuthorization: NGRlZjJkMWNlMDc5NGI5OTVlYTQxZDRkOGQ4NjRhNmZhNDgwZmIyNTZkMWJhN2M3MDdkNDI0ZWI1OGUwMGExMA==\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: api-cert.payeezy.com\r\nContent-Length: 365\r\n\r\n"
      <- "{\"transaction_type\":\"purchase\",\"merchant_ref\":null,\"method\":\"credit_card\",\"credit_card\":{\"type\":\"Visa\",\"cardholder_name\":\"Longbob Longsen\",\"card_number\":\"4242424242424242\",\"exp_date\":\"0916\",\"cvv\":\"123\"},\"billing_address\":{\"street\":\"456 My Street\",\"city\":\"Ottawa\",\"state_province\":\"ON\",\"zip_postal_code\":\"K1C2N6\",\"country\":\"CA\"},\"currency_code\":\"USD\",\"amount\":\"100\"}"
      -> "HTTP/1.1 201 Created\r\n"
      -> "Access-Control-Allow-Headers: Content-Type, apikey, token\r\n"
      -> "Access-Control-Allow-Methods: GET, PUT, POST, DELETE\r\n"
      -> "Access-Control-Allow-Origin: http://localhost:8080\r\n"
      -> "Access-Control-Max-Age: 3628800\r\n"
      -> "Access-Control-Request-Headers: origin, x-requested-with, accept, content-type\r\n"
      -> "Content-Language: en-US\r\n"
      -> "Content-Type: application/json;charset=UTF-8\r\n"
      -> "Date: Mon, 07 Dec 2015 21:29:08 GMT\r\n"
      -> "OPTR_CXT: 0100010000e4b64c5c-53c6-4f8b-aab6-b7950e2a40c100000000-0000-0000-0000-000000000000-1                                  HTTP    ;\r\n"
      -> "Server: Apigee Router\r\n"
      -> "X-Archived-Client-IP: 10.180.205.250\r\n"
      -> "X-Backside-Transport: OK OK,OK OK\r\n"
      -> "X-Client-IP: 10.180.205.250,54.236.202.5\r\n"
      -> "X-Global-Transaction-ID: 74768541\r\n"
      -> "X-Powered-By: Servlet/3.0\r\n"
      -> "Content-Length: 549\r\n"
      -> "Connection: Close\r\n"
      -> "\r\n"
      reading 549 bytes...
        -> "{\"correlation_id\":\"228.1449523748595\",\"transaction_status\":\"approved\",\"validation_status\":\"success\",\"transaction_type\":\"purchase\",\"transaction_id\":\"ET189831\",\"transaction_tag\":\"69607700\",\"method\":\"credit_card\",\"amount\":\"100\",\"currency\":\"USD\",\"avs\":\"4\",\"cvv2\":\"M\",\"token\":{\"token_type\":\"FDToken\",\"token_data\":{\"value\":\"1950935021264242\"}},\"card\":{\"type\":\"Visa\",\"cardholder_name\":\"Longbob Longsen\",\"card_number\":\"4242\",\"exp_date\":\"0916\"},\"bank_resp_code\":\"100\",\"bank_message\":\"Approved\",\"gateway_resp_code\":\"00\",\"gateway_message\":\"Transaction Normal\"}"
        read 549 bytes
        Conn close
    TRANSCRIPT
  end

  def post_scrubbed
    <<~TRANSCRIPT
      opening connection to api-cert.payeezy.com:443...
      opened
      starting SSL for api-cert.payeezy.com:443...
        SSL established
      <- "POST /v1/transactions HTTP/1.1\r\nContent-Type: application/json\r\nApikey: [FILTERED]\r\nToken: [FILTERED]\r\nNonce: 5803993876.636232\r\nTimestamp: 1449523748359\r\nAuthorization: NGRlZjJkMWNlMDc5NGI5OTVlYTQxZDRkOGQ4NjRhNmZhNDgwZmIyNTZkMWJhN2M3MDdkNDI0ZWI1OGUwMGExMA==\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: api-cert.payeezy.com\r\nContent-Length: 365\r\n\r\n"
      <- "{\"transaction_type\":\"purchase\",\"merchant_ref\":null,\"method\":\"credit_card\",\"credit_card\":{\"type\":\"Visa\",\"cardholder_name\":\"Longbob Longsen\",\"card_number\":\"[FILTERED]\",\"exp_date\":\"0916\",\"cvv\":\"[FILTERED]\"},\"billing_address\":{\"street\":\"456 My Street\",\"city\":\"Ottawa\",\"state_province\":\"ON\",\"zip_postal_code\":\"K1C2N6\",\"country\":\"CA\"},\"currency_code\":\"USD\",\"amount\":\"100\"}"
      -> "HTTP/1.1 201 Created\r\n"
      -> "Access-Control-Allow-Headers: Content-Type, apikey, token\r\n"
      -> "Access-Control-Allow-Methods: GET, PUT, POST, DELETE\r\n"
      -> "Access-Control-Allow-Origin: http://localhost:8080\r\n"
      -> "Access-Control-Max-Age: 3628800\r\n"
      -> "Access-Control-Request-Headers: origin, x-requested-with, accept, content-type\r\n"
      -> "Content-Language: en-US\r\n"
      -> "Content-Type: application/json;charset=UTF-8\r\n"
      -> "Date: Mon, 07 Dec 2015 21:29:08 GMT\r\n"
      -> "OPTR_CXT: 0100010000e4b64c5c-53c6-4f8b-aab6-b7950e2a40c100000000-0000-0000-0000-000000000000-1                                  HTTP    ;\r\n"
      -> "Server: Apigee Router\r\n"
      -> "X-Archived-Client-IP: 10.180.205.250\r\n"
      -> "X-Backside-Transport: OK OK,OK OK\r\n"
      -> "X-Client-IP: 10.180.205.250,54.236.202.5\r\n"
      -> "X-Global-Transaction-ID: 74768541\r\n"
      -> "X-Powered-By: Servlet/3.0\r\n"
      -> "Content-Length: 549\r\n"
      -> "Connection: Close\r\n"
      -> "\r\n"
      reading 549 bytes...
        -> "{\"correlation_id\":\"228.1449523748595\",\"transaction_status\":\"approved\",\"validation_status\":\"success\",\"transaction_type\":\"purchase\",\"transaction_id\":\"ET189831\",\"transaction_tag\":\"69607700\",\"method\":\"credit_card\",\"amount\":\"100\",\"currency\":\"USD\",\"avs\":\"4\",\"cvv2\":\"M\",\"token\":{\"token_type\":\"FDToken\",\"token_data\":{\"value\":\"1950935021264242\"}},\"card\":{\"type\":\"Visa\",\"cardholder_name\":\"Longbob Longsen\",\"card_number\":\"[FILTERED]\",\"exp_date\":\"0916\"},\"bank_resp_code\":\"100\",\"bank_message\":\"Approved\",\"gateway_resp_code\":\"00\",\"gateway_message\":\"Transaction Normal\"}"
        read 549 bytes
        Conn close
    TRANSCRIPT
  end

  def pre_scrubbed_echeck
    <<~TRANSCRIPT
      {\"transaction_type\":\"purchase\",\"merchant_ref\":null,\"method\":\"tele_check\",\"tele_check\":{\"check_number\":\"1\",\"check_type\":\"P\",\"routing_number\":\"244183602\",\"account_number\":\"15378535\",\"accountholder_name\":\"Jim Smith\"},\"billing_address\":{\"street\":\"456 My Street\",\"city\":\"Ottawa\",\"state_province\":\"ON\",\"zip_postal_code\":\"K1C2N6\",\"country\":\"CA\"},\"currency_code\":\"USD\",\"amount\":\"100\"}"
      -> "HTTP/1.1 201 Created\r\n"
      -> "Access-Control-Allow-Headers: Content-Type, apikey, token\r\n"
      -> "Access-Control-Allow-Methods: GET, PUT, POST, DELETE\r\n"
      -> "Access-Control-Allow-Origin: http://localhost:8080\r\n"
      -> "Access-Control-Max-Age: 3628800\r\n"
      -> "Access-Control-Request-Headers: origin, x-requested-with, accept, content-type\r\n"
      -> "Content-Language: en-US\r\n"
      -> "Content-Type: application/json;charset=UTF-8\r\n"
      -> "Date: Wed, 09 Dec 2015 19:33:14 GMT\r\n"
      -> "OPTR_CXT: 0100010000094b4179-bed8-4068-b077-d8679a20046f00000000-0000-0000-0000-000000000000-1                                  HTTP    ;\r\n"
      -> "Server: Apigee Router\r\n"
      -> "X-Archived-Client-IP: 10.180.205.250\r\n"
      -> "X-Backside-Transport: OK OK,OK OK\r\n"
      -> "X-Client-IP: 10.180.205.250,107.23.55.229\r\n"
      -> "X-Global-Transaction-ID: 97138449\r\n"
      -> "X-Powered-By: Servlet/3.0\r\n"
      -> "Content-Length: 491\r\n"
      -> "Connection: Close\r\n"
      -> "\r\n"
      reading 491 bytes...
      -> "{\"correlation_id\":\"228.1449689594381\",\"transaction_status\":\"approved\",\"validation_status\":\"success\",\"transaction_type\":\"purchase\",\"transaction_id\":\"ET196703\",\"transaction_tag\":\"69865571\",\"method\":\"tele_check\",\"amount\":\"100\",\"currency\":\"USD\",\"bank_resp_code\":\"100\",\"bank_message\":\"Approved\",\"gateway_resp_code\":\"00\",\"gateway_message\":\"Transaction Normal\",\"tele_check\":{\"accountholder_name\":\"Jim Smith\",\"check_number\":\"1\",\"check_type\":\"P\",\"account_number\":\"8535\",\"routing_number\":\"244183602\"}}
    TRANSCRIPT
  end

  def post_scrubbed_echeck
    <<~TRANSCRIPT
      {\"transaction_type\":\"purchase\",\"merchant_ref\":null,\"method\":\"tele_check\",\"tele_check\":{\"check_number\":\"1\",\"check_type\":\"P\",\"routing_number\":\"[FILTERED]\",\"account_number\":\"[FILTERED]\",\"accountholder_name\":\"Jim Smith\"},\"billing_address\":{\"street\":\"456 My Street\",\"city\":\"Ottawa\",\"state_province\":\"ON\",\"zip_postal_code\":\"K1C2N6\",\"country\":\"CA\"},\"currency_code\":\"USD\",\"amount\":\"100\"}"
      -> "HTTP/1.1 201 Created\r\n"
      -> "Access-Control-Allow-Headers: Content-Type, apikey, token\r\n"
      -> "Access-Control-Allow-Methods: GET, PUT, POST, DELETE\r\n"
      -> "Access-Control-Allow-Origin: http://localhost:8080\r\n"
      -> "Access-Control-Max-Age: 3628800\r\n"
      -> "Access-Control-Request-Headers: origin, x-requested-with, accept, content-type\r\n"
      -> "Content-Language: en-US\r\n"
      -> "Content-Type: application/json;charset=UTF-8\r\n"
      -> "Date: Wed, 09 Dec 2015 19:33:14 GMT\r\n"
      -> "OPTR_CXT: 0100010000094b4179-bed8-4068-b077-d8679a20046f00000000-0000-0000-0000-000000000000-1                                  HTTP    ;\r\n"
      -> "Server: Apigee Router\r\n"
      -> "X-Archived-Client-IP: 10.180.205.250\r\n"
      -> "X-Backside-Transport: OK OK,OK OK\r\n"
      -> "X-Client-IP: 10.180.205.250,107.23.55.229\r\n"
      -> "X-Global-Transaction-ID: 97138449\r\n"
      -> "X-Powered-By: Servlet/3.0\r\n"
      -> "Content-Length: 491\r\n"
      -> "Connection: Close\r\n"
      -> "\r\n"
      reading 491 bytes...
      -> "{\"correlation_id\":\"228.1449689594381\",\"transaction_status\":\"approved\",\"validation_status\":\"success\",\"transaction_type\":\"purchase\",\"transaction_id\":\"ET196703\",\"transaction_tag\":\"69865571\",\"method\":\"tele_check\",\"amount\":\"100\",\"currency\":\"USD\",\"bank_resp_code\":\"100\",\"bank_message\":\"Approved\",\"gateway_resp_code\":\"00\",\"gateway_message\":\"Transaction Normal\",\"tele_check\":{\"accountholder_name\":\"Jim Smith\",\"check_number\":\"1\",\"check_type\":\"P\",\"account_number\":\"[FILTERED]\",\"routing_number\":\"[FILTERED]\"}}
    TRANSCRIPT
  end

  def pre_scrubbed_store
    <<~TRANSCRIPT
      opening connection to api-cert.payeezy.com:443...
      opened
      starting SSL for api-cert.payeezy.com:443...
      SSL established
      <- "GET /v1/securitytokens?apikey=UyDMTXx6TD9WErF6ynw7xeEfCAn8fcGs&js_security_key=js-f4c4b54f08d6c44c8cad3ea80bbf92c4f4c4b54f08d6c44c&ta_token=120&callback=Payeezy.callback&type=FDToken&credit_card.type=Visa&credit_card.cardholder_name=Longbob+Longsen&credit_card.card_number=4242424242424242&credit_card.exp_date=0919&credit_card.cvv=123 HTTP/1.1\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: api-cert.payeezy.com\r\n\r\n"
      -> "HTTP/1.1 200 Success\r\n"
      -> "Content-Language: en-US\r\n"
      -> "Content-Type: application/json\r\n"
      -> "correlation_id: 228.1574930196886\r\n"
      -> "Date: Fri, 12 Jan 2018 09:28:22 GMT\r\n"
      -> "statuscode: 201\r\n"
      -> "X-Archived-Client-IP: 10.180.205.250\r\n"
      -> "X-Backside-Transport: OK OK,OK OK\r\n"
      -> "X-Client-IP: 10.180.205.250,54.218.45.37\r\n"
      -> "X-Global-Transaction-ID: 463881989\r\n"
      -> "X-Powered-By: Servlet/3.0\r\n"
      -> "Content-Length: 266\r\n"
      -> "Connection: Close\r\n"
      -> "\r\n"
      reading 266 bytes...
      -> "\n       Payeezy.callback({\n        \t\"status\":201,\n        \t\"results\":{\"correlation_id\":\"228.1574930196886\",\"status\":\"success\",\"type\":\"FDToken\",\"token\":{\"type\":\"Visa\",\"cardholder_name\":\"Longbob Longsen\",\"exp_date\":\"0919\",\"value\":\"2158545373614242\"}}\n        })\n      "
      read 266 bytes
      Conn close
    TRANSCRIPT
  end

  def post_scrubbed_store
    <<~TRANSCRIPT
      opening connection to api-cert.payeezy.com:443...
      opened
      starting SSL for api-cert.payeezy.com:443...
      SSL established
      <- "GET /v1/securitytokens?apikey=[FILTERED]js_security_key=js-f4c4b54f08d6c44c8cad3ea80bbf92c4f4c4b54f08d6c44c&ta_token=120&callback=Payeezy.callback&type=FDToken&credit_card.type=Visa&credit_card.cardholder_name=Longbob+Longsen&credit_card.card_number=[FILTERED]credit_card.exp_date=0919&credit_card.cvv=[FILTERED] HTTP/1.1\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: api-cert.payeezy.com\r\n\r\n"
      -> "HTTP/1.1 200 Success\r\n"
      -> "Content-Language: en-US\r\n"
      -> "Content-Type: application/json\r\n"
      -> "correlation_id: 228.1574930196886\r\n"
      -> "Date: Fri, 12 Jan 2018 09:28:22 GMT\r\n"
      -> "statuscode: 201\r\n"
      -> "X-Archived-Client-IP: 10.180.205.250\r\n"
      -> "X-Backside-Transport: OK OK,OK OK\r\n"
      -> "X-Client-IP: 10.180.205.250,54.218.45.37\r\n"
      -> "X-Global-Transaction-ID: 463881989\r\n"
      -> "X-Powered-By: Servlet/3.0\r\n"
      -> "Content-Length: 266\r\n"
      -> "Connection: Close\r\n"
      -> "\r\n"
      reading 266 bytes...
      -> "\n       Payeezy.callback({\n        \t\"status\":201,\n        \t\"results\":{\"correlation_id\":\"228.1574930196886\",\"status\":\"success\",\"type\":\"FDToken\",\"token\":{\"type\":\"Visa\",\"cardholder_name\":\"Longbob Longsen\",\"exp_date\":\"0919\",\"value\":\"2158545373614242\"}}\n        })\n      "
      read 266 bytes
      Conn close
    TRANSCRIPT
  end

  def pre_scrubbed_network_token
    <<~TRANSCRIPT
      opening connection to api-cert.payeezy.com:443...
      opened
      starting SSL for api-cert.payeezy.com:443...
      SSL established
      <- "POST /v1/transactions HTTP/1.1\r\nContent-Type: application/json\r\nApikey: oKB61AAxbN3xwC6gVAH3dp58FmioHSAT\r\nToken: fdoa-a480ce8951daa73262734cf102641994c1e55e7cdf4c02b6\r\nNonce: 2713241561.4909368\r\nTimestamp: 1668784714406\r\nAuthorization: NDU2ZWRiNmUwMmUxNGMwOGIwYjMxYTAxMDkzZDcwNWNhM2Y0ODExNmRmMTNjNDVjMTFhODMyNTg4NDdiNzZiNw==\r\nConnection: close\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nHost: api-cert.payeezy.com\r\nContent-Length: 462\r\n\r\n"
      <- "{\"transaction_type\":\"purchase\",\"merchant_ref\":null,\"3DS\":{\"type\":\"D\",\"cardholder_name\":\"Longbob\",\"card_number\":\"4761209980011439\",\"exp_date\":\"1122\",\"cvv\":569,\"xid\":\"YwAAAAAABaYcCMX/OhNRQAAAAAA=\",\"cavv\":\"YwAAAAAABaYcCMX/OhNRQAAAAAA=\",\"wallet_provider_id\":\"APPLE_PAY\"},\"method\":\"3DS\",\"eci_indicator\":5,\"billing_address\":{\"street\":\"456 My Street\",\"city\":\"Ottawa\",\"state_province\":\"ON\",\"zip_postal_code\":\"K1C2N6\",\"country\":\"CA\"},\"currency_code\":\"USD\",\"amount\":\"100\"}"
      -> "HTTP/1.1 201 Created\r\n"
      -> "Date: Fri, 18 Nov 2022 15:18:35 GMT\r\n"
      -> "Content-Type: application/json;charset=UTF-8\r\n"
      -> "Connection: close\r\n"
      -> "X-Backside-Transport: OK OK,OK OK\r\n"
      -> "Content-Language: en-US\r\n"
      -> "X-Global-Transaction-ID: 7f41427d6377a24aa50b34df\r\n"
      -> "Strict-Transport-Security: max-age=31536000; includeSubDomains\r\n"
      -> "X-Xss-Protection: 1; mode=block\r\n"
      -> "Cache-Control: no-store, no-cache, must-revalidate\r\n"
      -> "Pragma: no-cache\r\n"
      -> "X-Frame-Options: SAMEORIGIN\r\n"
      -> "Referrer-Policy: strict-origin\r\n"
      -> "Feature-Policy: vibrate 'self'\r\n"
      -> "Content-Security-Policy: default-src 'none'; frame-ancestors 'self'; script-src 'unsafe-inline' 'self' *.googleapis.com *.klarna.com *.masterpass.com *.mastercard.com *.newrelic.com *.npci.org.in *.nr-data.net *.google-analytics.com *.google.com *.getsitecontrol.com *.gstatic.com *.kxcdn.com 'strict-dynamic' 'nonce-6f62fa22a79de4c553d2bbde' 'unsafe-eval' 'unsafe-inline'; connect-src 'self'; img-src 'self'; style-src 'self'; base-uri 'self';\r\n"
      -> "Access-Control-Allow-Origin: http://localhost:8080\r\n"
      -> "Access-Control-Request-Headers: origin, x-requested-with, accept, content-type\r\n"
      -> "Access-Control-Max-Age: 3628800\r\n"
      -> "Access-Control-Allow-Methods: GET, PUT, POST, DELETE\r\n"
      -> "Access-Control-Allow-Headers: Content-Type, apikey, token\r\n"
      -> "Via: 1.1 dca1-bit16021\r\n"
      -> "Transfer-Encoding: chunked\r\n"
      -> "\r\n"
      -> "249\r\n"
      reading 585 bytes...
      -> "{\"correlation_id\":\"134.6878471461658\",\"transaction_status\":\"approved\",\"validation_status\":\"success\",\"transaction_type\":\"purchase\",\"transaction_id\":\"ET188163\",\"transaction_tag\":\"10032826722\",\"method\":\"3ds\",\"amount\":\"100\",\"currency\":\"USD\",\"avs\":\"4\",\"cvv2\":\"U\",\"token\":{\"token_type\":\"FDToken\",\"token_data\":{\"value\":\"9324008290401439\"}},\"card\":{\"type\":\"VISA\",\"cardholder_name\":\"Longbob\",\"card_number\":\"1439\",\"exp_date\":\"1122\"},\"bank_resp_code\":\"100\",\"bank_message\":\"Approved\",\"gateway_resp_code\":\"00\",\"gateway_message\":\"Transaction Normal\",\"eCommerce_flag\":\"5\",\"retrieval_ref_no\":\"221118\"}"
      read 585 bytes
      reading 2 bytes...
      -> "\r\n"
      read 2 bytes
      -> "0\r\n"
      -> "\r\n"
      Conn close
    TRANSCRIPT
  end

  def post_scrubbed_network_token
    <<~TRANSCRIPT
      opening connection to api-cert.payeezy.com:443...
      opened
      starting SSL for api-cert.payeezy.com:443...
      SSL established
      <- "POST /v1/transactions HTTP/1.1\r\nContent-Type: application/json\r\nApikey: [FILTERED]\r\nToken: [FILTERED]\r\nNonce: 2713241561.4909368\r\nTimestamp: 1668784714406\r\nAuthorization: NDU2ZWRiNmUwMmUxNGMwOGIwYjMxYTAxMDkzZDcwNWNhM2Y0ODExNmRmMTNjNDVjMTFhODMyNTg4NDdiNzZiNw==\r\nConnection: close\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nHost: api-cert.payeezy.com\r\nContent-Length: 462\r\n\r\n"
      <- "{\"transaction_type\":\"purchase\",\"merchant_ref\":null,\"3DS\":{\"type\":\"D\",\"cardholder_name\":\"Longbob\",\"card_number\":\"[FILTERED]\",\"exp_date\":\"1122\",\"cvv\":[FILTERED],\"xid\":[FILTERED],\"cavv\":[FILTERED],\"wallet_provider_id\":\"APPLE_PAY\"},\"method\":\"3DS\",\"eci_indicator\":5,\"billing_address\":{\"street\":\"456 My Street\",\"city\":\"Ottawa\",\"state_province\":\"ON\",\"zip_postal_code\":\"K1C2N6\",\"country\":\"CA\"},\"currency_code\":\"USD\",\"amount\":\"100\"}"
      -> "HTTP/1.1 201 Created\r\n"
      -> "Date: Fri, 18 Nov 2022 15:18:35 GMT\r\n"
      -> "Content-Type: application/json;charset=UTF-8\r\n"
      -> "Connection: close\r\n"
      -> "X-Backside-Transport: OK OK,OK OK\r\n"
      -> "Content-Language: en-US\r\n"
      -> "X-Global-Transaction-ID: 7f41427d6377a24aa50b34df\r\n"
      -> "Strict-Transport-Security: max-age=31536000; includeSubDomains\r\n"
      -> "X-Xss-Protection: 1; mode=block\r\n"
      -> "Cache-Control: no-store, no-cache, must-revalidate\r\n"
      -> "Pragma: no-cache\r\n"
      -> "X-Frame-Options: SAMEORIGIN\r\n"
      -> "Referrer-Policy: strict-origin\r\n"
      -> "Feature-Policy: vibrate 'self'\r\n"
      -> "Content-Security-Policy: default-src 'none'; frame-ancestors 'self'; script-src 'unsafe-inline' 'self' *.googleapis.com *.klarna.com *.masterpass.com *.mastercard.com *.newrelic.com *.npci.org.in *.nr-data.net *.google-analytics.com *.google.com *.getsitecontrol.com *.gstatic.com *.kxcdn.com 'strict-dynamic' 'nonce-6f62fa22a79de4c553d2bbde' 'unsafe-eval' 'unsafe-inline'; connect-src 'self'; img-src 'self'; style-src 'self'; base-uri 'self';\r\n"
      -> "Access-Control-Allow-Origin: http://localhost:8080\r\n"
      -> "Access-Control-Request-Headers: origin, x-requested-with, accept, content-type\r\n"
      -> "Access-Control-Max-Age: 3628800\r\n"
      -> "Access-Control-Allow-Methods: GET, PUT, POST, DELETE\r\n"
      -> "Access-Control-Allow-Headers: Content-Type, apikey, token\r\n"
      -> "Via: 1.1 dca1-bit16021\r\n"
      -> "Transfer-Encoding: chunked\r\n"
      -> "\r\n"
      -> "249\r\n"
      reading 585 bytes...
      -> "{\"correlation_id\":\"134.6878471461658\",\"transaction_status\":\"approved\",\"validation_status\":\"success\",\"transaction_type\":\"purchase\",\"transaction_id\":\"ET188163\",\"transaction_tag\":\"10032826722\",\"method\":\"3ds\",\"amount\":\"100\",\"currency\":\"USD\",\"avs\":\"4\",\"cvv2\":\"U\",\"token\":{\"token_type\":\"FDToken\",\"token_data\":{\"value\":\"9324008290401439\"}},\"card\":{\"type\":\"VISA\",\"cardholder_name\":\"Longbob\",\"card_number\":\"[FILTERED]\",\"exp_date\":\"1122\"},\"bank_resp_code\":\"100\",\"bank_message\":\"Approved\",\"gateway_resp_code\":\"00\",\"gateway_message\":\"Transaction Normal\",\"eCommerce_flag\":\"5\",\"retrieval_ref_no\":\"221118\"}"
      read 585 bytes
      reading 2 bytes...
      -> "\r\n"
      read 2 bytes
      -> "0\r\n"
      -> "\r\n"
      Conn close
    TRANSCRIPT
  end

  def successful_purchase_response
    <<~RESPONSE
      {\"method\":\"credit_card\",\"amount\":\"1\",\"currency\":\"USD\",\"avs\":\"4\",\"card\":{\"type\":\"Visa\",\"cardholder_name\":\"Bobsen 995\",\"card_number\":\"4242\",\"exp_date\":\"0816\"},\"token\":{\"token_type\":\"transarmor\",\"token_data\":{\"value\":\"0152552999534242\"}},\"transaction_status\":\"approved\",\"validation_status\":\"success\",\"transaction_type\":\"purchase\",\"transaction_id\":\"ET114541\",\"transaction_tag\":\"55083431\",\"bank_resp_code\":\"100\",\"bank_message\":\"Approved\",\"gateway_resp_code\":\"00\",\"gateway_message\":\"Transaction Normal\",\"correlation_id\":\"124.1433862672836\"}
    RESPONSE
  end

  def successful_purchase_stored_credentials_response
    '{"correlation_id":"228.4479800174823","transaction_status":"approved","validation_status":"success","transaction_type":"purchase","transaction_id":"ET117353","transaction_tag":"2309866208","method":"credit_card","amount":"100","currency":"USD","avs":"4","cvv2":"M","token":{"token_type":"FDToken","token_data":{"value":"9091469151414242"}},"card":{"type":"Visa","cardholder_name":"Longbob Longsen","card_number":"4242","exp_date":"0919"},"bank_resp_code":"100","bank_message":"Approved","gateway_resp_code":"00","gateway_message":"Transaction Normal","stored_credentials":{"cardbrand_original_transaction_id":"706838021010062"}}'
  end

  def successful_purchase_echeck_response
    <<~RESPONSE
      {\"correlation_id\":\"228.1449688619062\",\"transaction_status\":\"approved\",\"validation_status\":\"success\",\"transaction_type\":\"purchase\",\"transaction_id\":\"ET133078\",\"transaction_tag\":\"69864362\",\"method\":\"tele_check\",\"amount\":\"100\",\"currency\":\"USD\",\"bank_resp_code\":\"100\",\"bank_message\":\"Approved\",\"gateway_resp_code\":\"00\",\"gateway_message\":\"Transaction Normal\",\"tele_check\":{\"accountholder_name\":\"Jim Smith\",\"check_number\":\"1\",\"check_type\":\"P\",\"account_number\":\"8535\",\"routing_number\":\"244183602\"}}
    RESPONSE
  end

  def successful_store_response
    <<~RESPONSE
      {\"correlation_id\":\"124.1792879391754\",\"status\":\"success\",\"type\":\"FDToken\",\"token\":{\"type\":\"Visa\",\"cardholder_name\":\"Longbob Longsen\",\"exp_date\":\"0919\",\"value\":\"9045348309244242\"}}
    RESPONSE
  end

  def failed_store_response
    <<~RESPONSE
      {\"correlation_id\":\"124.1792940806770\",\"status\":\"failed\",\"Error\":{\"messages\":[{\"code\":\"invalid_card_number\",\"description\":\"The credit card number check failed\"}]},\"type\":\"FDToken\"}
    RESPONSE
  end

  def failed_purchase_response
    yamlexcep = <<~RESPONSE
      --- !ruby/exception:ActiveMerchant::ResponseError
      response: !ruby/object:Net::HTTPBadRequest
        http_version: '1.1'
        code: '400'
        message: Bad Request
        header:
          content-language:
          - en-US
          content-type:
          - application/json
          date:
          - Tue, 09 Jun 2015 15:46:44 GMT
          optr_cxt:
          - 0100010000eb11d301-785c-449b-b060-6d0b4638d54d00000000-0000-0000-0000-000000000000-1                                  HTTP    ;
          x-archived-client-ip:
          - 10.174.197.250
          x-backside-transport:
          - FAIL FAIL,FAIL FAIL
          x-client-ip:
          - 10.174.197.250,54.236.202.5
          x-powered-by:
          - Servlet/3.0
          content-length:
          - '384'
          connection:
          - Close
        body: '{"method":"credit_card","amount":"10000000","currency":"USD","card":{"type":"Visa","cvv":"000","cardholder_name":"Bobsen
          5675","card_number":"4242","exp_date":"0810"},"transaction_status":"Not Processed","validation_status":"failed","transaction_type":"purchase","Error":{"messages":[{"code":"card_expired","description":"The
          card has expired"}]},"correlation_id":"124.1433864804381"}'
        read: true
        uri:
        decode_content: true
        socket:
        body_exist: true
      message:
    RESPONSE
    YAML.safe_load(yamlexcep, permitted_classes: ['Net::HTTPBadRequest', 'ActiveMerchant::ResponseError'])
  end

  def failed_purchase_response_for_insufficient_funds
    '{"correlation_id":"124.1342365067332","transaction_status":"declined","validation_status":"success","transaction_type":"purchase","transaction_tag":"4611610442","method":"credit_card","amount":"530200","currency":"USD","avs":"4","cvv2":"M","token":{"token_type":"FDToken", "token_data":{"value":"0788934280684242"}},"card":{"type":"Visa","cardholder_name":"Longbob Longsen","card_number":"4242","exp_date":"0922"},"bank_resp_code":"302","bank_message":"Insufficient Funds","gateway_resp_code":"00","gateway_message":"Transaction Normal"}'
  end

  def successful_authorize_response
    <<~RESPONSE
      {\"correlation_id\":\"228.1449517682800\",\"transaction_status\":\"approved\",\"validation_status\":\"success\",\"transaction_type\":\"authorize\",\"transaction_id\":\"ET156862\",\"transaction_tag\":\"69601979\",\"method\":\"credit_card\",\"amount\":\"100\",\"currency\":\"USD\",\"avs\":\"4\",\"cvv2\":\"M\",\"token\":{\"token_type\":\"FDToken\",\"token_data\":{\"value\":\"1446473518714242\"}},\"card\":{\"type\":\"Visa\",\"cardholder_name\":\"Longbob Longsen\",\"card_number\":\"4242\",\"exp_date\":\"0916\"},\"bank_resp_code\":\"100\",\"bank_message\":\"Approved\",\"gateway_resp_code\":\"00\",\"gateway_message\":\"Transaction Normal\"}
    RESPONSE
  end

  def authorize_with_extra_space_in_transaction_id
    <<~RESPONSE
      {\"correlation_id\":\"228.1449517682800\",\"transaction_status\":\"approved\",\"validation_status\":\"success\",\"transaction_type\":\"authorize\",\"transaction_id\":\"ET176427 \",\"transaction_tag\":\"69601874\",\"method\":\"credit_card\",\"amount\":\"100\",\"currency\":\"USD\",\"avs\":\"4\",\"cvv2\":\"M\",\"token\":{\"token_type\":\"FDToken\",\"token_data\":{\"value\":\"1446473518714242\"}},\"card\":{\"type\":\"Visa\",\"cardholder_name\":\"Longbob Longsen\",\"card_number\":\"4242\",\"exp_date\":\"0916\"},\"bank_resp_code\":\"100\",\"bank_message\":\"Approved\",\"gateway_resp_code\":\"00\",\"gateway_message\":\"Transaction Normal\"}
    RESPONSE
  end

  def failed_authorize_response
    <<~RESPONSE
      {\"correlation_id\":\"228.1449522605561\",\"transaction_status\":\"declined\",\"validation_status\":\"success\",\"transaction_type\":\"authorize\",\"transaction_tag\":\"69607256\",\"method\":\"credit_card\",\"amount\":\"501300\",\"currency\":\"USD\",\"avs\":\"4\",\"cvv2\":\"M\",\"token\":{\"token_type\":\"FDToken\",\"token_data\":{\"value\":\"0843687226934242\"}},\"card\":{\"type\":\"Visa\",\"cardholder_name\":\"Longbob Longsen\",\"card_number\":\"4242\",\"exp_date\":\"0916\"},\"bank_resp_code\":\"013\",\"bank_message\":\"Transaction not approved\",\"gateway_resp_code\":\"00\",\"gateway_message\":\"Transaction Normal\"}
    RESPONSE
  end

  def successful_capture_response
    <<~RESPONSE
      {\"correlation_id\":\"228.1449517473876\",\"transaction_status\":\"approved\",\"validation_status\":\"success\",\"transaction_type\":\"capture\",\"transaction_id\":\"ET176427\",\"transaction_tag\":\"69601874\",\"method\":\"credit_card\",\"amount\":\"100\",\"currency\":\"USD\",\"cvv2\":\"I\",\"token\":{\"token_type\":\"FDToken\",\"token_data\":{\"value\":\"8129044621504242\"}},\"bank_resp_code\":\"100\",\"bank_message\":\"Approved\",\"gateway_resp_code\":\"00\",\"gateway_message\":\"Transaction Normal\"}
    RESPONSE
  end

  def successful_refund_response
    <<~RESPONSE
      {\"method\":\"credit_card\",\"amount\":\"1\",\"currency\":\"USD\",\"cvv2\":\"I\",\"token\":{\"token_type\":\"transarmor\",\"token_data\":{\"value\":\"9968749582724242\"}},\"transaction_status\":\"approved\",\"validation_status\":\"success\",\"transaction_type\":\"refund\",\"transaction_id\":\"55084328\",\"transaction_tag\":\"55084328\",\"bank_resp_code\":\"100\",\"bank_message\":\"Approved\",\"gateway_resp_code\":\"00\",\"gateway_message\":\"Transaction Normal\",\"correlation_id\":\"124.1433864648126\"}
    RESPONSE
  end

  def successful_refund_echeck_response
    <<~RESPONSE
      {\"correlation_id\":\"228.1449688783287\",\"transaction_status\":\"approved\",\"validation_status\":\"success\",\"transaction_type\":\"refund\",\"transaction_id\":\"69864710\",\"transaction_tag\":\"69864710\",\"method\":\"tele_check\",\"amount\":\"50\",\"currency\":\"USD\",\"bank_resp_code\":\"100\",\"bank_message\":\"Approved\",\"gateway_resp_code\":\"00\",\"gateway_message\":\"Transaction Normal\"}
    RESPONSE
  end

  def below_minimum_response
    <<~RESPONSE
      {\"correlation_id\":\"123.1234678982\",\"transaction_status\":\"declined\",\"validation_status\":\"success\",\"transaction_type\":\"authorize\",\"transaction_tag\":\"92384753\",\"method\":\"credit_card\",\"amount\":\"250\",\"currency\":\"USD\",\"card\":{\"type\":\"Mastercard\",\"cardholder_name\":\"Omri Test\",\"card_number\":\"[FILTERED]\",\"exp_date\":\"0123\"},\"gateway_resp_code\":\"36\",\"gateway_message\":\"Below Minimum Sale\"}
    RESPONSE
  end

  def failed_purchase_no_name_response
    <<~RESPONSE
      {\"correlation_id\":\"29.7337367613551\",\"transaction_status\":\"approved\",\"validation_status\":\"success\",\"transaction_type\":\"purchase\",\"transaction_id\":\"ET106024\",\"transaction_tag\":\"10049930801\",\"method\":\"3ds\",\"amount\":\"100\",\"currency\":\"USD\",\"avs\":\"4\",\"cvv2\":\"U\",\"token\":{\"token_type\":\"FDToken\",\"token_data\":{\"value\":\"1141044316391439\"}},\"card\":{\"type\":\"VISA\",\"cardholder_name\":\"Jim Smith\",\"card_number\":\"1439\",\"exp_date\":\"1124\"},\"bank_resp_code\":\"100\",\"bank_message\":\"Approved\",\"gateway_resp_code\":\"00\",\"gateway_message\":\"Transaction Normal\",\"eCommerce_flag\":\"5\",\"retrieval_ref_no\":\"230110\"}
    RESPONSE
  end

  def failed_refund_response
    yamlexcep = <<~RESPONSE
      --- !ruby/exception:ActiveMerchant::ResponseError
      response: !ruby/object:Net::HTTPBadRequest
        http_version: '1.1'
        code: '400'
        message: Bad Request
        header:
          content-language:
          - en-US
          content-type:
          - application/json
          date:
          - Tue, 09 Jun 2015 15:46:44 GMT
          optr_cxt:
          - 0100010000eb11d301-785c-449b-b060-6d0b4638d54d00000000-0000-0000-0000-000000000000-1                                  HTTP    ;
          x-archived-client-ip:
          - 10.174.197.250
          x-backside-transport:
          - FAIL FAIL,FAIL FAIL
          x-client-ip:
          - 10.174.197.250,54.236.202.5
          x-powered-by:
          - Servlet/3.0
          content-length:
          - '384'
          connection:
          - Close
        body: '{"correlation_id":"228.1449520714925","Error":{"messages":[{"code":"missing_transaction_tag","description":"The transaction tag is not provided"}]},"transaction_status":"Not Processed","validation_status":"failed","transaction_type":"refund","amount":"50","currency":"USD"}'
        read: true
        uri:
        decode_content: true
        socket:
        body_exist: true
      message:
    RESPONSE
    YAML.safe_load(yamlexcep, permitted_classes: ['Net::HTTPBadRequest', 'ActiveMerchant::ResponseError'])
  end

  def successful_void_response
    <<~RESPONSE
      {\"method\":\"credit_card\",\"amount\":\"1\",\"currency\":\"USD\",\"cvv2\":\"I\",\"token\":{\"token_type\":\"transarmor\",\"token_data\":{\"value\":\"9594258319174242\"}},\"transaction_status\":\"approved\",\"validation_status\":\"success\",\"transaction_type\":\"void\",\"transaction_id\":\"ET196233\",\"transaction_tag\":\"55083674\",\"bank_resp_code\":\"100\",\"bank_message\":\"Approved\",\"gateway_resp_code\":\"00\",\"gateway_message\":\"Transaction Normal\",\"correlation_id\":\"124.1433863576596\"}
    RESPONSE
  end

  def failed_void_response
    yamlexcep = <<~RESPONSE
      --- !ruby/exception:ActiveMerchant::ResponseError
      response: !ruby/object:Net::HTTPBadRequest
        http_version: '1.1'
        code: '400'
        message: Bad Request
        header:
          content-language:
          - en-US
          content-type:
          - application/json
          date:
          - Tue, 09 Jun 2015 15:46:44 GMT
          optr_cxt:
          - 0100010000eb11d301-785c-449b-b060-6d0b4638d54d00000000-0000-0000-0000-000000000000-1                                  HTTP    ;
          x-archived-client-ip:
          - 10.174.197.250
          x-backside-transport:
          - FAIL FAIL,FAIL FAIL
          x-client-ip:
          - 10.174.197.250,54.236.202.5
          x-powered-by:
          - Servlet/3.0
          content-length:
          - '384'
          connection:
          - Close
        body: '{"correlation_id":"228.1449520846984","Error":{"messages":[{"code":"missing_transaction_id","description":"The transaction id is not provided"},{"code":"missing_transaction_tag","description":"The transaction tag is not provided"}]},"transaction_status":"Not Processed","validation_status":"failed","transaction_type":"void","amount":"0","currency":"USD"}'
        read: true
        uri:
        decode_content: true
        socket:
        body_exist: true
      message:
    RESPONSE
    YAML.safe_load(yamlexcep, permitted_classes: ['Net::HTTPBadRequest', 'ActiveMerchant::ResponseError'])
  end

  def failed_capture_response
    yamlexcep = <<~RESPONSE
      --- !ruby/exception:ActiveMerchant::ResponseError
      response: !ruby/object:Net::HTTPBadRequest
        http_version: '1.1'
        code: '400'
        message: Bad Request
        header:
          content-language:
          - en-US
          content-type:
          - application/json
          date:
          - Tue, 09 Jun 2015 17:33:50 GMT
          optr_cxt:
          - 0100010000d084138f-24f3-4686-8a51-3c17406a572500000000-0000-0000-0000-000000000000-1                                  HTTP    ;
          x-archived-client-ip:
          - 10.174.197.250
          x-backside-transport:
          - FAIL FAIL,FAIL FAIL
          x-client-ip:
          - 10.174.197.250,107.23.55.229
          x-powered-by:
          - Servlet/3.0
          content-length:
          - '190'
          connection:
          - Close
        body: '{"transaction_status":"Not Processed","Error":{"messages":[{"code":"server_error","description":"ProcessedBad
          Request (69) - Invalid Transaction Tag"}]},"correlation_id":"124.1433871231542"}'
        read: true
        uri:
        decode_content: true
        socket:
        body_exist: true
      message:
    RESPONSE
    YAML.safe_load(yamlexcep, permitted_classes: ['Net::HTTPBadRequest', 'ActiveMerchant::ResponseError'])
  end

  def invalid_token_response
    yamlexcep = <<~RESPONSE
      --- !ruby/exception:ActiveMerchant::ResponseError
      response: !ruby/object:Net::HTTPUnauthorized
        http_version: '1.1'
        code: '401'
        message: Unauthorized
        header:
          content-language:
          - en-US
          content-type:
          - application/json;charset=utf-8
          date:
          - Tue, 23 Jun 2015 15:13:02 GMT
          optr_cxt:
          - 435543224354-37b2-4369-9cfe-26543635465346346-0000-0000-0000-000000000000-1                                  HTTP    ;
          x-archived-client-ip:
          - 10.180.205.250
          x-backside-transport:
          - FAIL FAIL,FAIL FAIL
          x-client-ip:
          - 10.180.205.250,107.23.55.229
          x-powered-by:
          - Servlet/3.0
          content-length:
          - '25'
          connection:
          - Close
        body: '{"error":"Access denied"}'
        read: true
        uri:
        decode_content: true
        socket:
        body_exist: true
      message:
    RESPONSE
    YAML.safe_load(yamlexcep, permitted_classes: ['Net::HTTPUnauthorized', 'ActiveMerchant::ResponseError'])
  end

  def invalid_token_response_integration
    yamlexcep = <<~RESPONSE
      --- !ruby/exception:ActiveMerchant::ResponseError
      response: !ruby/object:Net::HTTPUnauthorized
        http_version: '1.1'
        code: '401'
        message: Unauthorized
        header:
          content-type:
          - application/json
          content-length:
          - '125'
          connection:
          - Close
        body: '{\"fault\":{\"faultstring\":\"Invalid ApiKey for given resource\",\"detail\":{\"errorcode\":\"oauth.v2.InvalidApiKeyForGivenResource\"}}}'
        read: true
        uri:
        decode_content: true
        socket:
        body_exist: true
      message:
    RESPONSE
    YAML.safe_load(yamlexcep, permitted_classes: ['Net::HTTPUnauthorized', 'ActiveMerchant::ResponseError'])
  end

  def bad_credentials_response
    yamlexcep = <<~RESPONSE
      --- !ruby/exception:ActiveMerchant::ResponseError
      response: !ruby/object:Net::HTTPForbidden
        http_version: '1.1'
        code: '403'
        message: Forbidden
        header:
          content-type:
          - application/json
          content-length:
          - '51'
          connection:
          - Close
        body: '{"code":"403", "message":"HMAC validation Failure"}'
        read: true
        uri:
        decode_content: true
        socket:
        body_exist: true
      message:
    RESPONSE
    YAML.safe_load(yamlexcep, permitted_classes: ['Net::HTTPForbidden', 'ActiveMerchant::ResponseError'])
  end
end
