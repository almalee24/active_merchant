require 'test_helper'

class CheckoutV2Test < Test::Unit::TestCase
  include CommStub

  def setup
    @gateway = CheckoutV2Gateway.new(
      secret_key: '1111111111111'
    )
    @gateway_oauth = CheckoutV2Gateway.new({ client_id: 'abcd', client_secret: '1234', access_token: '12345678' })
    @gateway_api = CheckoutV2Gateway.new({
      secret_key: '1111111111111',
      public_key: '2222222222222'
    })
    @credit_card = credit_card
    @amount = 100
    @token = '2MPedsuenG2o8yFfrsdOBWmOuEf'

    @lvl_2_3_options = {
      order_id: '1',
      billing_address: address,
      shipping_address: address,
      description: 'Purchase',
      email: 'longbob.longsen@example.com',
      processing_channel_id: 'pc_lxgl7aqahkzubkundd2l546hdm',
      invoice_id: 12462,
      tax_number: 123456,
      from_address_zip: 12345,
      tax_amount: 30,
      shipping_amount: 20,
      discount_amount: 10,
      duty_amount: 5,
      line_items: [
        { # only for American Express in level 2 or any lvl 3
          commodity_code: 123,
          name: 'glass',
          quantity: 1,
          unit_price: 200,
          tax_amount: 12,
          discount_amount: 12,
          total_amount: 200,
          reference: 'glass123',
          unit_of_measure: 'Centimeters'
        },
        {
          commodity_code: 456,
          name: 'water',
          quantity: 2,
          unit_price: 100,
          tax_amount: 6,
          discount_amount: 6,
          total_amount: 100,
          reference: 'water123',
          unit_of_measure: 'Liters'
        }
      ]
    }
  end

  def test_supported_card_types
    assert_equal CheckoutV2Gateway.supported_cardtypes, %i[visa master american_express diners_club maestro discover jcb mada bp_plus patagonia_365 tarjeta_sol]
  end

  def test_setup_access_token_should_rise_an_exception_under_bad_request
    error = assert_raises(ActiveMerchant::OAuthResponseError) do
      @gateway.expects(:raw_ssl_request).returns(Net::HTTPBadRequest.new(1.0, 400, 'Bad Request'))
      @gateway.send(:setup_access_token)
    end

    assert_match(/Failed with 400 Bad Request/, error.message)
  end

  def test_successful_purchase
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card)
    end.respond_with(successful_purchase_response)

    assert_success response
    assert_equal 'pay_bgv5tmah6fmuzcmcrcro6exe6m', response.authorization
    assert response.test?
  end

  def test_successful_purchase_includes_avs_result
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card)
    end.respond_with(successful_purchase_response)

    assert_equal 'S', response.avs_result['code']
    assert_equal 'U.S.-issuing bank does not support AVS.', response.avs_result['message']
    assert_equal 'X', response.avs_result['postal_match']
    assert_equal 'X', response.avs_result['street_match']
  end

  def test_successful_purchase_includes_cvv_result
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card)
    end.respond_with(successful_purchase_response)

    assert_equal 'Y', response.cvv_result['code']
  end

  def test_successful_purchase_using_vts_network_token_without_eci
    network_token = network_tokenization_credit_card(
      '4242424242424242',
      { source: :network_token, brand: 'visa' }
    )
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, network_token)
    end.check_request do |_method, _endpoint, data, _headers|
      request_data = JSON.parse(data)

      assert_equal(request_data['source']['type'], 'network_token')
      assert_equal(request_data['source']['token'], network_token.number)
      assert_equal(request_data['source']['token_type'], 'vts')
      assert_equal(request_data['source']['eci'], '05')
      assert_equal(request_data['source']['cryptogram'], network_token.payment_cryptogram)
    end.respond_with(successful_purchase_with_network_token_response)

    assert_success response
    assert_equal '2FCFE326D92D4C27EDD699560F484', response.params['source']['payment_account_reference']
    assert response.test?
  end

  def test_successful_passing_processing_channel_id
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, { processing_channel_id: '123456abcde' })
    end.check_request do |_method, _endpoint, data, _headers|
      request_data = JSON.parse(data)
      assert_equal(request_data['processing_channel_id'], '123456abcde')
      assert_equal(request_data['metadata']['udf5'], 'ActiveMerchant')
    end.respond_with(successful_purchase_response)
  end

  def test_successful_passing_risk_data
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, {
        risk: {
          enabled: 'true',
          device_session_id: '12345-abcd'
        }
      })
    end.check_request do |_method, _endpoint, data, _headers|
      request = JSON.parse(data)['risk']
      assert_equal request['enabled'], true
      assert_equal request['device_session_id'], '12345-abcd'
      assert_equal JSON.parse(data)['metadata']['udf5'], 'ActiveMerchant'
    end.respond_with(successful_purchase_response)
  end

  def test_successful_passing_incremental_authorization
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.authorize(@amount, @credit_card, { incremental_authorization: 'abcd1234' })
    end.check_request do |_method, endpoint, data, _headers|
      assert_include endpoint, 'abcd1234'
      assert_equal JSON.parse(data)['metadata']['udf5'], 'ActiveMerchant'
    end.respond_with(successful_incremental_authorize_response)

    assert_success response
  end

  def test_successful_passing_authorization_type
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, { authorization_type: 'Estimated' })
    end.check_request do |_method, _endpoint, data, _headers|
      request_data = JSON.parse(data)
      assert_equal(request_data['authorization_type'], 'Estimated')
    end.respond_with(successful_purchase_response)
  end

  def test_successful_passing_exemption_and_challenge_indicator
    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, { execute_threed: true, exemption: 'no_preference', challenge_indicator: 'trusted_listing' })
    end.check_request do |_method, _endpoint, data, _headers|
      request_data = JSON.parse(data)
      assert_equal(request_data['3ds']['exemption'], 'no_preference')
      assert_equal(request_data['3ds']['challenge_indicator'], 'trusted_listing')
    end.respond_with(successful_purchase_response)
  end

  def test_successful_passing_capture_type
    stub_comms(@gateway, :ssl_request) do
      @gateway.capture(@amount, 'abc', { capture_type: 'NonFinal' })
    end.check_request do |_method, _endpoint, data, _headers|
      request_data = JSON.parse(data)
      assert_equal(request_data['capture_type'], 'NonFinal')
      assert_equal(request_data['metadata']['udf5'], 'ActiveMerchant')
    end.respond_with(successful_capture_response)
  end

  def test_successful_purchase_using_vts_network_token_with_eci
    network_token = network_tokenization_credit_card(
      '4242424242424242',
      { source: :network_token, brand: 'visa', eci: '06' }
    )
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, network_token)
    end.check_request do |_method, _endpoint, data, _headers|
      request_data = JSON.parse(data)

      assert_equal(request_data['source']['type'], 'network_token')
      assert_equal(request_data['source']['token'], network_token.number)
      assert_equal(request_data['source']['token_type'], 'vts')
      assert_equal(request_data['source']['eci'], '06')
      assert_equal(request_data['source']['cryptogram'], network_token.payment_cryptogram)
    end.respond_with(successful_purchase_with_network_token_response)

    assert_success response
    assert_equal '2FCFE326D92D4C27EDD699560F484', response.params['source']['payment_account_reference']
    assert response.test?
  end

  def test_successful_purchase_using_mdes_network_token
    network_token = network_tokenization_credit_card(
      '5436031030606378',
      { source: :network_token, brand: 'master' }
    )
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, network_token)
    end.check_request do |_method, _endpoint, data, _headers|
      request_data = JSON.parse(data)

      assert_equal(request_data['source']['type'], 'network_token')
      assert_equal(request_data['source']['token'], network_token.number)
      assert_equal(request_data['source']['token_type'], 'mdes')
      assert_equal(request_data['source']['eci'], nil)
      assert_equal(request_data['source']['cryptogram'], network_token.payment_cryptogram)
      assert_equal(request_data['metadata']['udf5'], 'ActiveMerchant')
    end.respond_with(successful_purchase_with_network_token_response)

    assert_success response
    assert_equal '2FCFE326D92D4C27EDD699560F484', response.params['source']['payment_account_reference']
    assert response.test?
  end

  def test_successful_purchase_using_apple_pay_network_token
    network_token = network_tokenization_credit_card(
      '4242424242424242',
      { source: :apple_pay, eci: '05', payment_cryptogram: 'AgAAAAAAAIR8CQrXcIhbQAAAAAA' }
    )
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, network_token)
    end.check_request do |_method, _endpoint, data, _headers|
      request_data = JSON.parse(data)

      assert_equal(request_data['source']['type'], 'network_token')
      assert_equal(request_data['source']['token'], network_token.number)
      assert_equal(request_data['source']['token_type'], 'applepay')
      assert_equal(request_data['source']['eci'], '05')
      assert_equal(request_data['source']['cryptogram'], network_token.payment_cryptogram)
      assert_equal(request_data['metadata']['udf5'], 'ActiveMerchant')
    end.respond_with(successful_purchase_with_network_token_response)

    assert_success response
    assert_equal '2FCFE326D92D4C27EDD699560F484', response.params['source']['payment_account_reference']
    assert response.test?
  end

  def test_successful_purchase_using_android_pay_network_token
    network_token = network_tokenization_credit_card(
      '4242424242424242',
      { source: :android_pay, eci: '05', payment_cryptogram: 'AgAAAAAAAIR8CQrXcIhbQAAAAAA' }
    )
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, network_token)
    end.check_request do |_method, _endpoint, data, _headers|
      request_data = JSON.parse(data)

      assert_equal(request_data['source']['type'], 'network_token')
      assert_equal(request_data['source']['token'], network_token.number)
      assert_equal(request_data['source']['token_type'], 'googlepay')
      assert_equal(request_data['source']['eci'], '05')
      assert_equal(request_data['source']['cryptogram'], network_token.payment_cryptogram)
      assert_equal(request_data['metadata']['udf5'], 'ActiveMerchant')
    end.respond_with(successful_purchase_with_network_token_response)

    assert_success response
    assert_equal '2FCFE326D92D4C27EDD699560F484', response.params['source']['payment_account_reference']
    assert response.test?
  end

  def test_successful_purchase_using_google_pay_network_token
    network_token = network_tokenization_credit_card(
      '4242424242424242',
      { source: :google_pay, eci: '05', payment_cryptogram: 'AgAAAAAAAIR8CQrXcIhbQAAAAAA' }
    )
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, network_token)
    end.check_request do |_method, _endpoint, data, _headers|
      request_data = JSON.parse(data)

      assert_equal(request_data['source']['type'], 'network_token')
      assert_equal(request_data['source']['token'], network_token.number)
      assert_equal(request_data['source']['token_type'], 'googlepay')
      assert_equal(request_data['source']['eci'], '05')
      assert_equal(request_data['source']['cryptogram'], network_token.payment_cryptogram)
      assert_equal(request_data['metadata']['udf5'], 'ActiveMerchant')
    end.respond_with(successful_purchase_with_network_token_response)

    assert_success response
    assert_equal '2FCFE326D92D4C27EDD699560F484', response.params['source']['payment_account_reference']
    assert response.test?
  end

  def test_successful_purchase_using_google_pay_pan_only_network_token
    network_token = network_tokenization_credit_card(
      '4242424242424242',
      { source: :google_pay }
    )
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, network_token)
    end.check_request do |_method, _endpoint, data, _headers|
      request_data = JSON.parse(data)

      assert_equal(request_data['source']['type'], 'network_token')
      assert_equal(request_data['source']['token'], network_token.number)
      assert_equal(request_data['source']['token_type'], 'googlepay')
      assert_equal(request_data['source']['eci'], nil)
      assert_equal(request_data['source']['cryptogram'], nil)
      assert_equal(request_data['metadata']['udf5'], 'ActiveMerchant')
    end.respond_with(successful_purchase_with_network_token_response)

    assert_success response
    assert_equal '2FCFE326D92D4C27EDD699560F484', response.params['source']['payment_account_reference']
    assert response.test?
  end

  def test_successful_render_for_oauth
    processing_channel_id = 'abcd123'
    response = stub_comms(@gateway_oauth, :ssl_request) do
      @gateway_oauth.purchase(@amount, @credit_card, { processing_channel_id: })
    end.check_request do |_method, endpoint, data, headers|
      if endpoint.match?(/token/)
        assert_equal headers['Authorization'], 'Basic YWJjZDoxMjM0'
        assert_equal data, 'grant_type=client_credentials'
      else
        request = JSON.parse(data)
        assert_equal headers['Authorization'], 'Bearer 12345678'
        assert_equal request['processing_channel_id'], processing_channel_id
        assert_equal request['metadata']['udf5'], 'ActiveMerchant'
      end
    end.respond_with(successful_access_token_response, successful_purchase_response)
    assert_success response
  end

  def test_successful_authorize_includes_avs_result
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.authorize(@amount, @credit_card)
    end.respond_with(successful_authorize_response)

    assert_equal 'S', response.avs_result['code']
    assert_equal 'U.S.-issuing bank does not support AVS.', response.avs_result['message']
    assert_equal 'X', response.avs_result['postal_match']
    assert_equal 'X', response.avs_result['street_match']
  end

  def test_successful_authorize_includes_cvv_result
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.authorize(@amount, @credit_card)
    end.respond_with(successful_authorize_response)

    assert_equal 'Y', response.cvv_result['code']
  end

  def test_purchase_with_additional_fields
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, { descriptor_city: 'london', descriptor_name: 'sherlock' })
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/"billing_descriptor\":{\"name\":\"sherlock\",\"city\":\"london\"}/, data)
    end.respond_with(successful_purchase_response)

    assert_success response
  end

  def test_verify_with_account_name_inquiry
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.verify(@credit_card, {
        account_holder: {
          type: 'individual',
          first_name: 'James',
          middle_name: 'John',
          last_name: 'Doe'
        },
        account_name_inquiry: true
      })
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"type":"individual"}, data)
      assert_match(%r{"first_name":"James"}, data)
      assert_match(%r{"middle_name":"John"}, data)
      assert_match(%r{"last_name":"Doe"}, data)
      assert_match(%r{"account_name_inquiry":true}, data)
    end.respond_with(successful_purchase_response)

    assert_success response
  end

  def test_verify_omits_account_holder_when_ani_flag_absent
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.verify(@credit_card, {
        account_holder: {
          type: 'individual',
          first_name: 'James',
          middle_name: 'John',
          last_name: 'Doe'
        }
      })
    end.check_request do |_method, _endpoint, data, _headers|
      refute_match(%r{"type":"individual"}, data)
      refute_match(%r{"first_name":"James"}, data)
      refute_match(%r{"middle_name":"John"}, data)
      refute_match(%r{"last_name":"Doe"}, data)
      refute_match(%r{"account_name_inquiry":true}, data)
    end.respond_with(successful_purchase_response)

    assert_success response
  end

  def test_purchase_with_recipient_fields
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, {
        recipient: {
          dob: '1985-05-15',
          account_number: '5555554444',
          zip: 'SW1A',
          first_name: 'john',
          last_name: 'johnny',
          address: {
            address_line1: '123 High St.',
            address_line2: 'Flat 456',
            city: 'London',
            state: 'str',
            zip: 'SW1A 1AA',
            country: 'GB'
          }
        }
      })
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"dob":"1985-05-15"}, data)
      assert_match(%r{"account_number":"5555554444"}, data)
      assert_match(%r{"zip":"SW1A"}, data)
      assert_match(%r{"first_name":"john"}, data)
      assert_match(%r{"last_name":"johnny"}, data)
      assert_match(%r{"address_line1":"123 High St."}, data)
      assert_match(%r{"address_line2":"Flat 456"}, data)
      assert_match(%r{"city":"London"}, data)
      assert_match(%r{"state":"str"}, data)
      assert_match(%r{"zip":"SW1A 1AA"}, data)
      assert_match(%r{"country":"GB"}, data)
    end.respond_with(successful_purchase_response)

    assert_success response
  end

  def test_purchase_with_sender_fields
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, {
        sender: {
          type: 'individual',
          date_of_birth: '1985-05-15',
          first_name: 'Jane',
          last_name: 'Doe',
          address: {
            address1: '123 High St.',
            address2: 'Flat 456',
            city: 'London',
            state: 'str',
            zip: 'SW1A 1AA',
            country: 'GB'
          },
          reference: '8285282045818',
          identification: {
            type: 'passport',
            number: 'ABC123',
            issuing_country: 'GB'
          }
        }
      })
    end.check_request do |_method, _endpoint, data, _headers|
      request = JSON.parse(data)['sender']
      assert_equal request['first_name'], 'Jane'
      assert_equal request['last_name'], 'Doe'
      assert_equal request['type'], 'individual'
      assert_equal request['date_of_birth'], '1985-05-15'
      assert_equal request['reference'], '8285282045818'
      assert_equal request['address']['address_line1'], '123 High St.'
      assert_equal request['address']['address_line2'], 'Flat 456'
      assert_equal request['address']['city'], 'London'
      assert_equal request['address']['state'], 'str'
      assert_equal request['address']['zip'], 'SW1A 1AA'
      assert_equal request['address']['country'], 'GB'
      assert_equal request['identification']['type'], 'passport'
      assert_equal request['identification']['number'], 'ABC123'
      assert_equal request['identification']['issuing_country'], 'GB'
    end.respond_with(successful_purchase_response)

    assert_success response
  end

  def test_purchase_with_processing_fields
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, {
        processing: {
          aft: true
        }
      })
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"aft":true}, data)
    end.respond_with(successful_purchase_response)

    assert_success response
  end

  def test_successful_purchase_passing_metadata_with_mada_card_type
    @credit_card.brand = 'mada'

    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card)
    end.check_request do |_method, _endpoint, data, _headers|
      request_data = JSON.parse(data)
      assert_equal(request_data['metadata']['udf1'], 'mada')
    end.respond_with(successful_purchase_response)
  end

  def test_failed_purchase
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card)
    end.respond_with(failed_purchase_response)
    assert_failure response
    assert_equal Gateway::STANDARD_ERROR_CODE[:invalid_number], response.error_code
  end

  def test_failed_purchase_3ds
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, { execute_threed: true, exemption: 'no_preference', challenge_indicator: 'trusted_listing' })
    end.respond_with(failed_purchase_3ds_response)

    assert_failure response
    assert_equal 'Insufficient Funds', response.message
    assert_equal nil, response.error_code
  end

  def test_successful_authorize_and_capture
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.authorize(@amount, @credit_card)
    end.respond_with(successful_authorize_response)

    assert_success response
    assert_equal 'pay_fj3xswqe3emuxckocjx6td73ni', response.authorization

    capture = stub_comms(@gateway, :ssl_request) do
      @gateway.capture(@amount, response.authorization)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"metadata":{"udf5":"ActiveMerchant"}}, data)
    end.respond_with(successful_capture_response)

    assert_success capture
  end

  def test_successful_authorize_and_capture_with_additional_options
    response = stub_comms(@gateway, :ssl_request) do
      options = {
        card_on_file: true,
        transaction_indicator: 2,
        previous_charge_id: 'pay_123',
        processing_channel_id: 'pc_123'
      }
      @gateway.authorize(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"stored":"true"}, data)
      assert_match(%r{"payment_type":"Recurring"}, data)
      assert_match(%r{"previous_payment_id":"pay_123"}, data)
      assert_match(%r{"processing_channel_id":"pc_123"}, data)
    end.respond_with(successful_authorize_response)

    assert_success response
    assert_equal 'pay_fj3xswqe3emuxckocjx6td73ni', response.authorization

    capture = stub_comms(@gateway, :ssl_request) do
      @gateway.capture(@amount, response.authorization)
    end.respond_with(successful_capture_response)

    assert_success capture
  end

  def test_successful_purchase_with_stored_credentials
    initial_response = stub_comms(@gateway, :ssl_request) do
      initial_options = {
        stored_credential: {
          initiator: 'cardholder',
          initial_transaction: true,
          reason_type: 'installment'
        }
      }
      @gateway.purchase(@amount, @credit_card, initial_options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"payment_type":"Installment"}, data)
      assert_match(%r{"merchant_initiated":false}, data)
    end.respond_with(successful_purchase_initial_stored_credential_response)

    assert_success initial_response
    assert_equal 'pay_7jcf4ovmwnqedhtldca3fjli2y', initial_response.params['id']
    network_transaction_id = initial_response.params['id']

    response = stub_comms(@gateway, :ssl_request) do
      options = {
        stored_credential: {
          initial_transaction: false,
          reason_type: 'recurring',
          network_transaction_id:
        }
      }
      @gateway.purchase(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal request['previous_payment_id'], 'pay_7jcf4ovmwnqedhtldca3fjli2y'
      assert_equal request['source']['stored'], true
    end.respond_with(successful_purchase_using_stored_credential_response)

    assert_success response
    assert_equal 'Succeeded', response.message
  end

  def test_successful_purchase_with_stored_credentials_merchant_initiated_transaction_id
    response = stub_comms(@gateway, :ssl_request) do
      options = {
        stored_credential: {
          initial_transaction: false
        },
        merchant_initiated_transaction_id: 'pay_7jcf4ovmwnqedhtldca3fjli2y'
      }
      @gateway.purchase(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal request['previous_payment_id'], 'pay_7jcf4ovmwnqedhtldca3fjli2y'
      assert_equal request['source']['stored'], true
    end.respond_with(successful_purchase_using_stored_credential_response)

    assert_success response
    assert_equal 'Succeeded', response.message
  end

  def test_successful_purchase_with_extra_customer_data
    stub_comms(@gateway, :ssl_request) do
      options = {
        phone_country_code: '1',
        billing_address: address
      }
      @gateway.purchase(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal request['source']['phone']['number'], '(555)555-5555'
      assert_equal request['source']['phone']['country_code'], '1'
      assert_equal request['customer']['name'], 'Longbob Longsen'
    end.respond_with(successful_purchase_response)
  end

  def test_successful_purchase_with_partial_authorization
    stub_comms(@gateway, :ssl_request) do
      options = {
        phone_country_code: '1',
        billing_address: address,
        processing_channel_id: 'pc_aaco6s3z7jbepo7dzdpmdcnfcy',
        partial_authorization: true
      }
      @gateway.purchase(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal request['partial_authorization']['enabled'], true
      assert_equal request['processing_channel_id'], 'pc_aaco6s3z7jbepo7dzdpmdcnfcy'
    end.respond_with(successful_purchase_response)
  end

  def test_no_customer_name_included_in_token_purchase
    stub_comms(@gateway, :ssl_request) do
      options = {
        phone_country_code: '1',
        billing_address: address
      }
      @gateway.purchase(@amount, @token, options)
    end.check_request do |_method, _endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal request['source']['phone']['number'], '(555)555-5555'
      assert_equal request['source']['phone']['country_code'], '1'
      refute_includes data, 'name'
    end.respond_with(successful_purchase_response)
  end

  def test_successful_purchase_with_metadata
    response = stub_comms(@gateway, :ssl_request) do
      options = {
        metadata: {
          coupon_code: 'NY2018',
          partner_id: '123989'
        }
      }
      @gateway.purchase(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"coupon_code":"NY2018"}, data)
      assert_match(%r{"partner_id":"123989"}, data)
    end.respond_with(successful_purchase_using_stored_credential_response)

    assert_success response
  end

  def test_optional_idempotency_key_and_bearer_inclution_in_header
    stub_comms(@gateway, :ssl_request) do
      options = {
        idempotency_key: 'test123'
      }
      @gateway.purchase(@amount, @credit_card, options)
    end.check_request do |_method, _url, _data, headers|
      assert_equal 'test123', headers['Cko-Idempotency-Key']
      assert_match 'Bearer', headers['Authorization']
    end.respond_with(successful_authorize_response)
  end

  def test_successful_authorize_and_capture_with_metadata
    response = stub_comms(@gateway, :ssl_request) do
      options = {
        metadata: {
          coupon_code: 'NY2018',
          partner_id: '123989'
        }
      }
      @gateway.authorize(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"coupon_code":"NY2018"}, data)
      assert_match(%r{"partner_id":"123989"}, data)
    end.respond_with(successful_authorize_response)

    assert_success response
    assert_equal 'pay_fj3xswqe3emuxckocjx6td73ni', response.authorization

    capture = stub_comms(@gateway, :ssl_request) do
      @gateway.capture(@amount, response.authorization)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"metadata":{"udf5":"ActiveMerchant"}}, data)
    end.respond_with(successful_capture_response)

    assert_success capture
  end

  def test_moto_transaction_is_properly_set
    response = stub_comms(@gateway, :ssl_request) do
      options = {
        metadata: {
          manual_entry: true
        }
      }
      @gateway.authorize(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"payment_type":"MOTO"}, data)
    end.respond_with(successful_authorize_response)

    assert_success response
  end

  def test_3ds_passed
    response = stub_comms(@gateway, :ssl_request) do
      options = {
        execute_threed: true,
        callback_url: 'https://www.example.com'
      }
      @gateway.authorize(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"success_url"}, data)
      assert_match(%r{"failure_url"}, data)
      assert_match(%r{"metadata":{"udf5":"ActiveMerchant"}}, data)
    end.respond_with(successful_authorize_response)

    assert_success response
  end

  def test_successful_verify_payment
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.verify_payment('testValue')
    end.respond_with(successful_verify_payment_response)
    assert_success response
  end

  def test_verify_payment_request
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.verify_payment('testValue')
    end.check_request do |_method, endpoint, data, _headers|
      assert_equal nil, data
      assert_equal 'https://api.sandbox.checkout.com/payments/testValue', endpoint
    end.respond_with(successful_verify_payment_response)
    assert_success response
  end

  def test_failed_verify_payment
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.verify_payment('testValue')
    end.respond_with(failed_verify_payment_response)

    assert_failure response
  end

  def test_successful_authorize_and_capture_with_3ds
    response = stub_comms(@gateway, :ssl_request) do
      options = {
        execute_threed: true,
        attempt_n3d: true,
        three_d_secure: {
          version: '1.0.2',
          eci: '05',
          cryptogram: '1234',
          xid: '1234',
          authentication_response_status: 'Y'
        }
      }
      @gateway.authorize(@amount, @credit_card, options)
    end.respond_with(successful_authorize_response)

    assert_success response
    assert_equal 'pay_fj3xswqe3emuxckocjx6td73ni', response.authorization

    capture = stub_comms(@gateway, :ssl_request) do
      @gateway.capture(@amount, response.authorization)
    end.respond_with(successful_capture_response)

    assert_success capture
  end

  def test_successful_authorize_and_capture_with_3ds2
    response = stub_comms(@gateway, :ssl_request) do
      options = {
        execute_threed: true,
        three_d_secure: {
          version: '2.0.0',
          eci: '05',
          cryptogram: '1234',
          ds_transaction_id: '1234',
          authentication_response_status: 'Y'
        }
      }
      @gateway.authorize(@amount, @credit_card, options)
    end.respond_with(successful_authorize_response)

    assert_success response
    assert_equal 'pay_fj3xswqe3emuxckocjx6td73ni', response.authorization

    capture = stub_comms(@gateway, :ssl_request) do
      @gateway.capture(@amount, response.authorization)
    end.respond_with(successful_capture_response)

    assert_success capture
  end

  def test_failed_authorize
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.authorize(@amount, @credit_card)
    end.respond_with(failed_authorize_response)

    assert_failure response
    assert_equal 'Invalid Card Number', response.message
    assert response.test?
  end

  def test_failed_capture
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.capture(100, '')
    end.respond_with(failed_capture_response)

    assert_failure response
  end

  def test_successful_void
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.authorize(@amount, @credit_card)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"metadata":{"udf5":"ActiveMerchant"}}, data)
    end.respond_with(successful_authorize_response)

    assert_success response
    assert_equal 'pay_fj3xswqe3emuxckocjx6td73ni', response.authorization

    void = stub_comms(@gateway, :ssl_request) do
      @gateway.void(response.authorization)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"metadata":{"udf5":"ActiveMerchant"}}, data)
    end.respond_with(successful_void_response)

    assert_success void
  end

  def test_successful_void_with_metadata
    response = stub_comms(@gateway, :ssl_request) do
      options = {
        metadata: {
          coupon_code: 'NY2018',
          partner_id: '123989'
        }
      }
      @gateway.authorize(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"coupon_code":"NY2018"}, data)
      assert_match(%r{"partner_id":"123989"}, data)
    end.respond_with(successful_authorize_response)

    assert_success response
    assert_equal 'pay_fj3xswqe3emuxckocjx6td73ni', response.authorization

    void = stub_comms(@gateway, :ssl_request) do
      @gateway.void(response.authorization)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"metadata":{"udf5":"ActiveMerchant"}}, data)
    end.respond_with(successful_void_response)

    assert_success void
  end

  def test_failed_void
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.void('5d53a33d960c46d00f5dc061947d998c')
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"metadata":{"udf5":"ActiveMerchant"}}, data)
    end.respond_with(failed_void_response)
    assert_failure response
  end

  def test_successfully_passes_fund_type_and_fields
    options = {
      funds_transfer_type: 'FD',
      source_type: 'currency_account',
      source_id: 'ca_spwmped4qmqenai7hcghquqle4',
      account_holder_type: 'individual',
      metadata: { transaction_token: '123' }
    }
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.credit(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal request['instruction']['funds_transfer_type'], options[:funds_transfer_type]
      assert_equal request['source']['type'], options[:source_type]
      assert_equal request['source']['id'], options[:source_id]
      assert_equal request['destination']['account_holder']['type'], options[:account_holder_type]
      assert_equal request['destination']['account_holder']['first_name'], @credit_card.first_name
      assert_equal request['destination']['account_holder']['last_name'], @credit_card.last_name
      assert_equal request['metadata']['transaction_token'], '123'
      assert_match request['metadata']['udf5'], 'ActiveMerchant'
    end.respond_with(successful_credit_response)
    assert_success response
  end

  def test_successful_money_transfer_payout_via_credit
    options = {
      instruction_purpose: 'leisure',
      account_holder_type: 'individual',
      billing_address: address,
      payout: true,
      destination: {
        account_holder: {
          phone: {
            number: '9108675309',
            country_code: '1'
          },
          identification: {
            type: 'passport',
            number: '1234567890'
          },
          email: 'too_many_fields@checkout.com',
          date_of_birth: '2004-10-27',
          country_of_birth: 'US'
        }
      },
      sender: {
        type: 'individual',
        first_name: 'Jane',
        middle_name: 'Middle',
        last_name: 'Doe',
        reference: '012345',
        reference_type: 'other',
        source_of_funds: 'debit',
        identification: {
          type: 'passport',
          number: '0987654321',
          issuing_country: 'US',
          date_of_expiry: '2027-07-07'
        },
        address: {
          address1: '205 Main St',
          address2: 'Apt G',
          city: 'Winchestertonfieldville',
          state: 'IA',
          country: 'US',
          zip: '12345'
        },
        date_of_birth: '2004-10-27',
        country_of_birth: 'US',
        nationality: 'US'
      }
    }
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.credit(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal request['instruction']['purpose'], 'leisure'
      assert_equal request['destination']['account_holder']['phone']['number'], '9108675309'
      assert_equal request['destination']['account_holder']['phone']['country_code'], '1'
      assert_equal request['destination']['account_holder']['identification']['number'], '1234567890'
      assert_equal request['destination']['account_holder']['identification']['type'], 'passport'
      assert_equal request['destination']['account_holder']['email'], 'too_many_fields@checkout.com'
      assert_equal request['destination']['account_holder']['date_of_birth'], '2004-10-27'
      assert_equal request['destination']['account_holder']['country_of_birth'], 'US'
      assert_equal request['sender']['type'], 'individual'
      assert_equal request['sender']['first_name'], 'Jane'
      assert_equal request['sender']['middle_name'], 'Middle'
      assert_equal request['sender']['last_name'], 'Doe'
      assert_equal request['sender']['reference'], '012345'
      assert_equal request['sender']['reference_type'], 'other'
      assert_equal request['sender']['source_of_funds'], 'debit'
      assert_equal request['sender']['identification']['type'], 'passport'
      assert_equal request['sender']['identification']['number'], '0987654321'
      assert_equal request['sender']['identification']['issuing_country'], 'US'
      assert_equal request['sender']['identification']['date_of_expiry'], '2027-07-07'
      assert_equal request['sender']['address']['address_line1'], '205 Main St'
      assert_equal request['sender']['address']['address_line2'], 'Apt G'
      assert_equal request['sender']['address']['city'], 'Winchestertonfieldville'
      assert_equal request['sender']['address']['state'], 'IA'
      assert_equal request['sender']['address']['country'], 'US'
      assert_equal request['sender']['address']['zip'], '12345'
      assert_equal request['sender']['date_of_birth'], '2004-10-27'
      assert_equal request['sender']['nationality'], 'US'
      assert_match request['metadata']['udf5'], 'ActiveMerchant'
    end.respond_with(successful_credit_response)
    assert_success response
  end

  def test_payout_transaction_successfully_continues_with_no_sender_data
    options = {
      instruction_purpose: 'leisure',
      account_holder_type: 'individual',
      billing_address: address,
      payout: true,
      destination: {
        account_holder: {
          phone: {
            number: '9108675309',
            country_code: '1'
          },
          identification: {
            type: 'passport',
            number: '1234567890'
          },
          email: 'too_many_fields@checkout.com',
          date_of_birth: '2004-10-27',
          country_of_birth: 'US'
        }
      }
    }
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.credit(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      refute_includes data, 'sender'
    end.respond_with(successful_credit_response)
    assert_success response
  end

  def test_transaction_successfully_reverts_to_regular_credit_when_payout_is_nil
    options = {
      instruction_purpose: 'leisure',
      account_holder_type: 'individual',
      billing_address: address,
      payout: nil,
      destination: {
        account_holder: {
          email: 'too_many_fields@checkout.com'
        }
      },
      sender: {
        type: 'individual'
      }
    }
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.credit(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      refute_includes data, 'email'
      refute_includes data, 'sender'
    end.respond_with(successful_credit_response)
    assert_success response
  end

  def test_successful_refund
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card)
    end.respond_with(successful_purchase_response)

    assert_success response
    assert_equal 'pay_bgv5tmah6fmuzcmcrcro6exe6m', response.authorization

    refund = stub_comms(@gateway, :ssl_request) do
      @gateway.refund(@amount, response.authorization)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"metadata":{"udf5":"ActiveMerchant"}}, data)
    end.respond_with(successful_refund_response)

    assert_success refund
  end

  def test_successful_refund_with_metadata
    response = stub_comms(@gateway, :ssl_request) do
      options = {
        metadata: {
          coupon_code: 'NY2018',
          partner_id: '123989'
        }
      }
      @gateway.authorize(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"coupon_code":"NY2018"}, data)
      assert_match(%r{"partner_id":"123989"}, data)
      assert_match(%r{"udf5":"ActiveMerchant"}, data)
    end.respond_with(successful_purchase_response)

    assert_success response
    assert_equal 'pay_bgv5tmah6fmuzcmcrcro6exe6m', response.authorization

    refund = stub_comms(@gateway, :ssl_request) do
      @gateway.refund(@amount, response.authorization)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"metadata":{"udf5":"ActiveMerchant"}}, data)
    end.respond_with(successful_refund_response)

    assert_success refund
  end

  def test_failed_refund
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.refund(nil, '')
    end.respond_with(failed_refund_response)

    assert_failure response
  end

  def test_successful_verify
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.verify(@credit_card)
    end.respond_with(successful_verify_response)
    assert_success response
    assert_equal 'Succeeded', response.message
  end

  def test_failed_verify
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.verify(@credit_card)
    end.respond_with(failed_verify_response)
    assert_failure response
    assert_equal 'request_invalid: card_number_invalid', response.message
  end

  def test_successful_store
    stub_comms(@gateway, :ssl_request) do
      @gateway.store(@credit_card)
    end.check_request do |_method, endpoint, data, _headers|
      if /tokens/.match?(endpoint)
        assert_match(%r{"type":"card"}, data)
        assert_match(%r{"number":"4242424242424242"}, data)
        assert_match(%r{"cvv":"123"}, data)
        assert_match('/tokens', endpoint)
      elsif /instruments/.match?(endpoint)
        assert_match(%r{"type":"token"}, data)
        assert_match(%r{"token":"tok_}, data)
        assert_match(%r{"metadata":{"udf5":"ActiveMerchant"}}, data)
      end
    end.respond_with(succesful_token_response, succesful_store_response)
  end

  def test_successful_tokenize
    stub_comms(@gateway, :ssl_request) do
      @gateway.send(:tokenize, @credit_card)
    end.check_request do |_action, endpoint, data, _headers|
      assert_match(%r{"type":"card"}, data)
      assert_match(%r{"number":"4242424242424242"}, data)
      assert_match(%r{"cvv":"123"}, data)
      assert_match('/tokens', endpoint)
    end.respond_with(succesful_token_response)
  end

  def test_transcript_scrubbing
    assert_equal post_scrubbed, @gateway.scrub(pre_scrubbed)
  end

  def test_network_transaction_scrubbing
    assert_equal network_transaction_post_scrubbed, @gateway.scrub(network_transaction_pre_scrubbed)
  end

  def test_invalid_json
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card)
    end.respond_with(invalid_json_response)

    assert_failure response
    assert_match %r{Invalid JSON response received from Checkout.com Unified Payments Gateway. Please contact Checkout.com if you continue to receive this message.}, response.message
  end

  def test_error_code_returned
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card)
    end.respond_with(error_code_response)

    assert_failure response
    assert_match(/request_invalid: card_expired/, response.error_code)
  end

  def test_error_type_without_error_code_returned
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card)
    end.respond_with(error_type_without_error_codes_response)

    assert_failure response
    assert_match(/request_invalid/, response.error_code)
  end

  def test_4xx_error_message
    @gateway.expects(:ssl_request).raises(error_4xx_response)

    assert response = @gateway.purchase(@amount, @credit_card)

    assert_failure response
    assert_match(/401: Unauthorized/, response.message)
  end

  def test_supported_countries
    assert_equal %w[AD AE AR AT AU BE BG BH BR CH CL CN CO CY CZ DE DK EE EG ES FI FR GB GR HK HR HU IE IS IT JO JP KW LI LT LU LV MC MT MX MY NL NO NZ OM PE PL PT QA RO SA SE SG SI SK SM TR US], @gateway.supported_countries
  end

  def test_add_shipping_address
    options = {
      shipping_address: address()
    }
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.authorize(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal request['shipping']['address']['address_line1'], options[:shipping_address][:address1]
      assert_equal request['shipping']['address']['address_line2'], options[:shipping_address][:address2]
      assert_equal request['shipping']['address']['city'], options[:shipping_address][:city]
      assert_equal request['shipping']['address']['state'], options[:shipping_address][:state]
      assert_equal request['shipping']['address']['country'], options[:shipping_address][:country]
      assert_equal request['shipping']['address']['zip'], options[:shipping_address][:zip]
      assert_equal request['metadata']['udf5'], 'ActiveMerchant'
    end.respond_with(successful_authorize_response)

    assert_success response
    assert_equal 'Succeeded', response.message
  end

  def test_purchase_supports_alternate_credit_card_implementation
    alternate_credit_card_class = Class.new
    alternate_credit_card = alternate_credit_card_class.new

    alternate_credit_card.expects(:credit_card?).returns(true)
    alternate_credit_card.expects(:name).at_least_once.returns(@credit_card.name)
    alternate_credit_card.expects(:number).returns(@credit_card.number)
    alternate_credit_card.expects(:verification_value).returns(@credit_card.verification_value)
    alternate_credit_card.expects(:first_name).at_least_once.returns(@credit_card.first_name)
    alternate_credit_card.expects(:last_name).at_least_once.returns(@credit_card.first_name)

    stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, alternate_credit_card)
    end.respond_with(successful_purchase_response)
  end

  def test_authorize_supports_alternate_credit_card_implementation
    alternate_credit_card_class = Class.new
    alternate_credit_card = alternate_credit_card_class.new

    alternate_credit_card.expects(:credit_card?).returns(true)
    alternate_credit_card.expects(:name).at_least_once.returns(@credit_card.name)
    alternate_credit_card.expects(:number).returns(@credit_card.number)
    alternate_credit_card.expects(:verification_value).returns(@credit_card.verification_value)
    alternate_credit_card.expects(:first_name).at_least_once.returns(@credit_card.first_name)
    alternate_credit_card.expects(:last_name).at_least_once.returns(@credit_card.first_name)

    stub_comms(@gateway, :ssl_request) do
      @gateway.authorize(@amount, alternate_credit_card)
    end.respond_with(successful_authorize_response)
  end

  def test_authorize_with_level_2_3_data
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.authorize(@amount, @credit_card, @lvl_2_3_options)
    end.check_request do |_method, _endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal request.dig('customer', 'tax_number'), 123456
      assert_equal request.dig('processing', 'order_id'), 12462
      assert_equal request.dig('processing', 'tax_amount'), 30
      assert_equal request.dig('processing', 'discount_amount'), 10
      assert_equal request.dig('processing', 'shipping_amount'), 20
      assert_equal request.dig('processing', 'duty_amount'), 5
      assert_equal request.dig('shipping', 'from_address_zip'), 12345
      assert_equal request['metadata']['udf5'], 'ActiveMerchant'

      item_one = request['items'][0]
      item_two = request['items'][1]

      assert_equal item_one['reference'], 'glass123'
      assert_equal item_one['name'], 'glass'
      assert_equal item_one['quantity'], 1
      assert_equal item_one['unit_price'], 200
      assert_equal item_one['tax_amount'], 12
      assert_equal item_one['discount_amount'], 12
      assert_equal item_one['total_amount'], 200
      assert_equal item_one['commodity_code'], 123
      assert_equal item_one['unit_of_measure'], 'Centimeters'

      assert_equal item_two['reference'], 'water123'
      assert_equal item_two['name'], 'water'
      assert_equal item_two['quantity'], 2
      assert_equal item_two['unit_price'], 100
      assert_equal item_two['tax_amount'], 6
      assert_equal item_two['discount_amount'], 6
      assert_equal item_two['total_amount'], 100
      assert_equal item_two['commodity_code'], 456
      assert_equal item_two['unit_of_measure'], 'Liters'
    end.respond_with(successful_authorize_response)

    assert_success response
    assert_equal 'Succeeded', response.message
    assert_equal 'pay_fj3xswqe3emuxckocjx6td73ni', response.authorization
  end

  def test_capture_with_level_2_3_data
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.capture(@amount, 'some_value', @lvl_2_3_options)
    end.check_request do |_method, _endpoint, data, _headers|
      request = JSON.parse(data)
      assert_equal request.dig('customer', 'tax_number'), 123456
      assert_equal request.dig('processing', 'order_id'), 12462
      assert_equal request.dig('processing', 'tax_amount'), 30
      assert_equal request.dig('processing', 'discount_amount'), 10
      assert_equal request.dig('processing', 'duty_amount'), 5
      assert_equal request.dig('processing', 'shipping_amount'), 20
      assert_equal request.dig('shipping', 'from_address_zip'), 12345

      item_one = request['items'][0]
      item_two = request['items'][1]

      assert_equal item_one['name'], 'glass'
      assert_equal item_one['quantity'], 1
      assert_equal item_one['unit_price'], 200
      assert_equal item_one['reference'], 'glass123'
      assert_equal item_one['commodity_code'], 123
      assert_equal item_one['unit_of_measure'], 'Centimeters'
      assert_equal item_one['total_amount'], 200
      assert_equal item_one['tax_amount'], 12
      assert_equal item_one['discount_amount'], 12

      assert_equal item_two['reference'], 'water123'
      assert_equal item_two['name'], 'water'
      assert_equal item_two['quantity'], 2
      assert_equal item_two['unit_price'], 100
      assert_equal item_two['tax_amount'], 6
      assert_equal item_two['discount_amount'], 6
      assert_equal item_two['total_amount'], 100
      assert_equal item_two['commodity_code'], 456
      assert_equal item_two['unit_of_measure'], 'Liters'
    end.respond_with(successful_capture_response)

    assert_success response
    assert_equal 'Succeeded', response.message
  end

  def test_payment_type_is_regular_when_reason_type_is_unscheduled_and_initiator_is_cardholder
    stub_comms(@gateway, :ssl_request) do
      initial_options = {
        stored_credential: {
          initiator: 'cardholder',
          reason_type: 'unscheduled'
        }
      }
      @gateway.purchase(@amount, @credit_card, initial_options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"payment_type":"Regular"}, data)
    end.respond_with(successful_purchase_initial_stored_credential_response)
  end

  def test_payment_type_is_not_changed_when_reason_type_is_unscheduled_and_initiator_is_merchant
    stub_comms(@gateway, :ssl_request) do
      initial_options = {
        stored_credential: {
          initiator: 'merchant',
          reason_type: 'unscheduled'
        }
      }
      @gateway.purchase(@amount, @credit_card, initial_options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(%r{"payment_type":"Unscheduled"}, data)
    end.respond_with(successful_purchase_initial_stored_credential_response)
  end

  private

  def pre_scrubbed
    %q(
      <- "POST /payments HTTP/1.1\r\nContent-Type: application/json;charset=UTF-8\r\nAuthorization: sk_test_ab12301d-e432-4ea7-97d1-569809518aaf\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: api.checkout.com\r\nContent-Length: 346\r\n\r\n"
      <- "{\"capture\":false,\"amount\":\"200\",\"reference\":\"1\",\"currency\":\"USD\",\"source\":{\"type\":\"card\",\"name\":\"Longbob Longsen\",\"number\":\"4242424242424242\",\"cvv\":\"100\",\"expiry_year\":\"2025\"
    )
  end

  def network_transaction_pre_scrubbed
    %q(
      <- "POST /payments HTTP/1.1\r\nContent-Type: application/json;charset=UTF-8\r\nAuthorization: sk_test_ab12301d-e432-4ea7-97d1-569809518aaf\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: api.checkout.com\r\nContent-Length: 346\r\n\r\n"
      <- "{\"amount\":\"100\",\"reference\":\"1\",\"currency\":\"USD\",\"metadata\":{\"udf5\":\"ActiveMerchant\"},\"source\":{\"type\":\"network_token\",\"token\":\"4242424242424242\",\"token_type\":\"applepay\",\"cryptogram\":\"AgAAAAAAAIR8CQrXcIhbQAAAAAA\",\"eci\":\"05\",\"expiry_year\":\"2025\",\"expiry_month\":\"10\",\"billing_address\":{\"address_line1\":\"456 My Street\",\"address_line2\":\"Apt 1\",\"city\":\"Ottawa\",\"state\":\"ON\",\"country\":\"CA\",\"zip\":\"K1C2N6\"}},\"customer\":{\"email\":\"longbob.longsen@example.com\"}}"
    )
  end

  def network_transaction_post_scrubbed
    %q(
      <- "POST /payments HTTP/1.1\r\nContent-Type: application/json;charset=UTF-8\r\nAuthorization: [FILTERED]\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: api.checkout.com\r\nContent-Length: 346\r\n\r\n"
      <- "{\"amount\":\"100\",\"reference\":\"1\",\"currency\":\"USD\",\"metadata\":{\"udf5\":\"ActiveMerchant\"},\"source\":{\"type\":\"network_token\",\"token\":\"[FILTERED]\",\"token_type\":\"applepay\",\"cryptogram\":\"[FILTERED]\",\"eci\":\"05\",\"expiry_year\":\"2025\",\"expiry_month\":\"10\",\"billing_address\":{\"address_line1\":\"456 My Street\",\"address_line2\":\"Apt 1\",\"city\":\"Ottawa\",\"state\":\"ON\",\"country\":\"CA\",\"zip\":\"K1C2N6\"}},\"customer\":{\"email\":\"longbob.longsen@example.com\"}}"
    )
  end

  def post_scrubbed
    %q(
      <- "POST /payments HTTP/1.1\r\nContent-Type: application/json;charset=UTF-8\r\nAuthorization: [FILTERED]\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: api.checkout.com\r\nContent-Length: 346\r\n\r\n"
      <- "{\"capture\":false,\"amount\":\"200\",\"reference\":\"1\",\"currency\":\"USD\",\"source\":{\"type\":\"card\",\"name\":\"Longbob Longsen\",\"number\":\"[FILTERED]\",\"cvv\":\"[FILTERED]\",\"expiry_year\":\"2025\"
    )
  end

  def successful_access_token_response
    %(
      {"access_token":"12345678","expires_in":3600,"token_type":"Bearer","scope":"disputes:accept disputes:provide-evidence disputes:view files flow:events flow:workflows fx gateway gateway:payment gateway:payment-authorizations gateway:payment-captures gateway:payment-details gateway:payment-refunds gateway:payment-voids middleware middleware:merchants-secret payouts:bank-details risk sessions:app sessions:browser vault:instruments"}
    )
  end

  def successful_purchase_response
    %(
      {"id":"pay_bgv5tmah6fmuzcmcrcro6exe6m","action_id":"act_bgv5tmah6fmuzcmcrcro6exe6m","amount":200,"currency":"USD","approved":true,"status":"Authorized","auth_code":"127172","eci":"05","scheme_id":"096091887499308","response_code":"10000","response_summary":"Approved","risk":{"flagged":false},"source":{"id":"src_fzp3cwkf4ygebbmvrxdhyrwmbm","type":"card","billing_address":{"address_line1":"456 My Street","address_line2":"Apt 1","city":"Ottawa","state":"ON","zip":"K1C2N6","country":"CA"},"expiry_month":6,"expiry_year":2025,"name":"Longbob Longsen","scheme":"Visa","last4":"4242","fingerprint":"9F3BAD2E48C6C8579F2F5DC0710B7C11A8ACD5072C3363A72579A6FB227D64BE","bin":"424242","card_type":"Credit","card_category":"Consumer","issuer":"JPMORGAN CHASE BANK NA","issuer_country":"US","product_id":"A","product_type":"Visa Traditional","avs_check":"S","cvv_check":"Y","payouts":true,"fast_funds":"d"},"customer":{"id":"cus_tz76qzbwr44ezdfyzdvrvlwogy","email":"longbob.longsen@example.com","name":"Longbob Longsen"},"processed_on":"2020-09-11T13:58:32Z","reference":"1","processing":{"acquirer_transaction_id":"9819327011","retrieval_reference_number":"861613285622"},"_links":{"self":{"href":"https://api.sandbox.checkout.com/payments/pay_bgv5tmah6fmuzcmcrcro6exe6m"},"actions":{"href":"https://api.sandbox.checkout.com/payments/pay_bgv5tmah6fmuzcmcrcro6exe6m/actions"},"capture":{"href":"https://api.sandbox.checkout.com/payments/pay_bgv5tmah6fmuzcmcrcro6exe6m/captures"},"void":{"href":"https://api.sandbox.checkout.com/payments/pay_bgv5tmah6fmuzcmcrcro6exe6m/voids"}}}
    )
  end

  def succesful_store_response
    %(
      {"id":"src_vzzqipykt5ke5odazx5d7nikii","type":"card","fingerprint":"9F3BAD2E48C6C8579F2F5DC0710B7C11A8ACD5072C3363A72579A6FB227D64BE","expiry_month":6,"expiry_year":2025,"scheme":"VISA","last4":"4242","bin":"424242","card_type":"CREDIT","card_category":"CONSUMER","issuer_country":"GB","product_id":"F","product_type":"Visa Classic","customer":{"id":"cus_gmthnluatgounpoiyzbmn5fvua", "email":"longbob.longsen@example.com"}}
    )
  end

  def successful_purchase_with_network_token_response
    purchase_response = JSON.parse(successful_purchase_response)
    purchase_response['source']['payment_account_reference'] = '2FCFE326D92D4C27EDD699560F484'
    purchase_response.to_json
  end

  def successful_purchase_initial_stored_credential_response
    %(
      {"id":"pay_7jcf4ovmwnqedhtldca3fjli2y","action_id":"act_7jcf4ovmwnqedhtldca3fjli2y","amount":200,"currency":"USD","approved":true,"status":"Authorized","auth_code":"587541","eci":"05","scheme_id":"776561034288791","response_code":"10000","response_summary":"Approved","risk":{"flagged":false},"source":{"id":"src_m2ooveyd2dxuzh277ft4obgkwm","type":"card","billing_address":{"address_line1":"456 My Street","address_line2":"Apt 1","city":"Ottawa","state":"ON","zip":"K1C2N6","country":"CA"},"expiry_month":6,"expiry_year":2025,"name":"Longbob Longsen","scheme":"Visa","last4":"4242","fingerprint":"9F3BAD2E48C6C8579F2F5DC0710B7C11A8ACD5072C3363A72579A6FB227D64BE","bin":"424242","card_type":"Credit","card_category":"Consumer","issuer":"JPMORGAN CHASE BANK NA","issuer_country":"US","product_id":"A","product_type":"Visa Traditional","avs_check":"S","cvv_check":"Y","payouts":true,"fast_funds":"d"},"customer":{"id":"cus_tr53e5z2dlmetpo2ehbsuk76yu","email":"longbob.longsen@example.com","name":"Longbob Longsen"},"processed_on":"2021-03-29T20:22:48Z","reference":"1","processing":{"acquirer_transaction_id":"8266949399","retrieval_reference_number":"731420439000"},"_links":{"self":{"href":"https://api.sandbox.checkout.com/payments/pay_7jcf4ovmwnqedhtldca3fjli2y"},"actions":{"href":"https://api.sandbox.checkout.com/payments/pay_7jcf4ovmwnqedhtldca3fjli2y/actions"},"capture":{"href":"https://api.sandbox.checkout.com/payments/pay_7jcf4ovmwnqedhtldca3fjli2y/captures"},"void":{"href":"https://api.sandbox.checkout.com/payments/pay_7jcf4ovmwnqedhtldca3fjli2y/voids"}}}
    )
  end

  def successful_purchase_using_stored_credential_response
    %(
      {"id":"pay_udodtu4ogljupp2jvy2cxf4jme","action_id":"act_udodtu4ogljupp2jvy2cxf4jme","amount":200,"currency":"USD","approved":true,"status":"Authorized","auth_code":"680745","eci":"05","scheme_id":"491049486700108","response_code":"10000","response_summary":"Approved","risk":{"flagged":false},"source":{"id":"src_m2ooveyd2dxuzh277ft4obgkwm","type":"card","billing_address":{"address_line1":"456 My Street","address_line2":"Apt 1","city":"Ottawa","state":"ON","zip":"K1C2N6","country":"CA"},"expiry_month":6,"expiry_year":2025,"name":"Longbob Longsen","scheme":"Visa","last4":"4242","fingerprint":"9F3BAD2E48C6C8579F2F5DC0710B7C11A8ACD5072C3363A72579A6FB227D64BE","bin":"424242","card_type":"Credit","card_category":"Consumer","issuer":"JPMORGAN CHASE BANK NA","issuer_country":"US","product_id":"A","product_type":"Visa Traditional","avs_check":"S","cvv_check":"Y","payouts":true,"fast_funds":"d"},"customer":{"id":"cus_tr53e5z2dlmetpo2ehbsuk76yu","email":"longbob.longsen@example.com","name":"Longbob Longsen"},"processed_on":"2021-03-29T20:22:49Z","reference":"1","processing":{"acquirer_transaction_id":"4026777708","retrieval_reference_number":"633985559433"},"_links":{"self":{"href":"https://api.sandbox.checkout.com/payments/pay_udodtu4ogljupp2jvy2cxf4jme"},"actions":{"href":"https://api.sandbox.checkout.com/payments/pay_udodtu4ogljupp2jvy2cxf4jme/actions"},"capture":{"href":"https://api.sandbox.checkout.com/payments/pay_udodtu4ogljupp2jvy2cxf4jme/captures"},"void":{"href":"https://api.sandbox.checkout.com/payments/pay_udodtu4ogljupp2jvy2cxf4jme/voids"}}}
    )
  end

  def failed_purchase_response
    %(
     {
       "id":"pay_awjzhfj776gulbp2nuslj4agbu",
       "amount":200,
       "currency":"USD",
       "reference":"1",
       "response_summary": "Invalid Card Number",
       "response_code":"20014",
       "customer": {
        "id": "cus_zvnv7gsblfjuxppycd7bx4erue",
        "email": "longbob.longsen@example.com",
        "name": "Sarah Mitchell"
       },
       "source": {
         "cvvCheck":"Y",
         "avsCheck":"S"
       }
      }
    )
  end

  def failed_purchase_3ds_response
    %({
        "id": "pay_awjzhfj776gulbp2nuslj4agbu",
        "requested_on": "2019-08-14T18:13:54Z",
        "source": {
          "id": "src_lot2ch4ygk3ehi4fugxmk7r2di",
          "type": "card",
          "expiry_month": 12,
          "expiry_year": 2020,
          "name": "Jane Doe",
          "scheme": "Visa",
          "last4": "0907",
          "fingerprint": "E4048195442B0059D73FD47F6E1961A02CD085B0B34B7703CE4A93750DB5A0A1",
          "bin": "457382",
          "avs_check": "S",
          "cvv_check": "Y"
        },
        "amount": 100,
        "currency": "USD",
        "payment_type": "Regular",
        "reference": "Dvy8EMaEphrMWolKsLVHcUqPsyx",
        "status": "Declined",
        "approved": false,
        "3ds": {
          "downgraded": false,
          "enrolled": "Y",
          "authentication_response": "Y",
          "cryptogram": "ce49b5c1-5d3c-4864-bd16-2a8c",
          "xid": "95202312-f034-48b4-b9b2-54254a2b49fb",
          "version": "2.1.0"
        },
        "risk": {
          "flagged": false
        },
        "customer": {
          "id": "cus_zt5pspdtkypuvifj7g6roy7p6y",
          "name": "Jane Doe"
        },
        "billing_descriptor": {
          "name": "",
          "city": "London"
        },
        "payment_ip": "127.0.0.1",
        "metadata": {
          "Udf5": "ActiveMerchant"
        },
        "eci": "05",
        "scheme_id": "638284745624527",
        "actions": [
          {
            "id": "act_tkvif5mf54eerhd3ysuawfcnt4",
            "type": "Authorization",
            "response_code": "20051",
            "response_summary": "Insufficient Funds"
          }
        ],
        "_links": {
          "self": {
            "href": "https://api.sandbox.checkout.com/payments/pay_tkvif5mf54eerhd3ysuawfcnt4"
          },
          "actions": {
            "href": "https://api.sandbox.checkout.com/payments/pay_tkvif5mf54eerhd3ysuawfcnt4/actions"
          },
          "capture": {
            "href": "https://api.sandbox.checkout.com/payments/pay_tkvif5mf54eerhd3ysuawfcnt4/captures"
          },
          "void": {
            "href": "https://api.sandbox.checkout.com/payments/pay_tkvif5mf54eerhd3ysuawfcnt4/voids"
          }
        }
      })
  end

  def successful_authorize_response
    %(
    {
      "id": "pay_fj3xswqe3emuxckocjx6td73ni",
      "action_id": "act_fj3xswqe3emuxckocjx6td73ni",
      "amount": 200,
      "currency": "USD",
      "approved": true,
      "status": "Authorized",
      "auth_code": "858188",
      "eci": "05",
      "scheme_id": "638284745624527",
      "response_code": "10000",
      "response_summary": "Approved",
      "risk": {
        "flagged": false
      },
      "source": {
        "id": "src_nq6m5dqvxmsunhtzf7adymbq3i",
        "type": "card",
        "expiry_month": 8,
        "expiry_year": 2025,
        "name": "Sarah Mitchell",
        "scheme": "Visa",
        "last4": "4242",
        "fingerprint": "5CD3B9CB15338683110959D165562D23084E1FF564F420FE9A990DF0BCD093FC",
        "bin": "424242",
        "card_type": "Credit",
        "card_category": "Consumer",
        "issuer": "JPMORGAN CHASE BANK NA",
        "issuer_country": "US",
        "product_id": "A",
        "product_type": "Visa Traditional",
        "avs_check": "S",
        "cvv_check": "Y"
      },
      "customer": {
        "id": "cus_ssxcidkqvfde7lfn5n7xzmgv2a",
        "email": "longbob.longsen@example.com",
        "name": "Sarah Mitchell"
      },
      "processed_on": "2019-03-24T10:14:32Z",
      "reference": "ORD-5023-4E89",
      "_links": {
        "self": {
          "href": "https://api.sandbox.checkout.com/payments/pay_fj3xswqe3emuxckocjx6td73ni"
        },
        "actions": {
          "href": "https://api.sandbox.checkout.com/payments/pay_fj3xswqe3emuxckocjx6td73ni/actions"
        },
        "capture": {
          "href": "https://api.sandbox.checkout.com/payments/pay_fj3xswqe3emuxckocjx6td73ni/captures"
        },
        "void": {
          "href": "https://api.sandbox.checkout.com/payments/pay_fj3xswqe3emuxckocjx6td73ni/voids"
        }
      }
    }
  )
  end

  def failed_authorize_response
    %(
     {
       "id":"pay_awjzhfj776gulbp2nuslj4agbu",
       "amount":200,
       "currency":"USD",
       "reference":"1",
       "customer": {
        "id": "cus_zvnv7gsblfjuxppycd7bx4erue",
        "email": "longbob.longsen@example.com",
        "name": "Sarah Mitchell"
       },
       "response_summary": "Invalid Card Number",
       "response_code":"20014"
      }
    )
  end

  def successful_incremental_authorize_response
    %(
      {
        "action_id": "act_q4dbxom5jbgudnjzjpz7j2z6uq",
        "amount": 50,
        "currency": "USD",
        "approved": true,
        "status": "Authorized",
        "auth_code": "503198",
        "expires_on": "2020-04-20T10:11:12Z",
        "eci": "05",
        "scheme_id": "511129554406717",
        "response_code": "10000",
        "response_summary": "Approved",
        "balances": {
          "total_authorized": 150,
          "total_voided": 0,
          "available_to_void": 150,
          "total_captured": 0,
          "available_to_capture": 150,
          "total_refunded": 0,
          "available_to_refund": 0
        },
        "processed_on": "2020-03-16T22:11:24Z",
        "reference": "ORD-752-814",
        "processing": {
          "acquirer_transaction_id": "8367314942",
          "retrieval_reference_number": "162588399162"
        },
        "_links": {
          "self": {
            "href": "https://api.sandbox.checkout.com/payments/pay_tqgk5c6k2nnexagtcuom5ktlua"
          },
          "actions": {
            "href": "https://api.sandbox.checkout.com/payments/pay_tqgk5c6k2nnexagtcuom5ktlua/actions"
          },
          "authorize": {
            "href": "https://api.sandbox.checkout.com/payments/pay_tqgk5c6k2nnexagtcuom5ktlua/authorizations"
          },
          "capture": {
            "href": "https://api.sandbox.checkout.com/payments/pay_tqgk5c6k2nnexagtcuom5ktlua/captures"
          },
          "void": {
            "href": "https://api.sandbox.checkout.com/payments/pay_tqgk5c6k2nnexagtcuom5ktlua/voids"
          }
        }
      }
    )
  end

  def successful_capture_response
    %(
    {
     "action_id": "act_2f56bhkau5dubequbv5aa6w4qi",
     "reference": "1"
    }
    )
  end

  def failed_capture_response
    %(
    )
  end

  def successful_refund_response
    %(
    {
     "action_id": "act_2f56bhkau5dubequbv5aa6w4qi",
     "reference": "1"
    }
    )
  end

  def failed_refund_response
    %(
    )
  end

  def successful_void_response
    %(
    {
     "action_id": "act_2f56bhkau5dubequbv5aa6w4qi",
     "reference": "1"
    }
    )
  end

  def successful_credit_response
    %(
    {
      "id": "pay_jhzh3u7vxcgezlcek7ymzyy6be",
      "status": "Pending",
      "reference": "ORD-5023-4E89",
      "instruction": {
          "value_date": "2022-08-09T06:11:37.2306547+00:00"
      },
      "_links": {
          "self": {
              "href": "https://api.sandbox.checkout.com/payments/pay_jhzh3u7vxcgezlcek7ymzyy6be"
          },
          "actions": {
              "href": "https://api.sandbox.checkout.com/payments/pay_jhzh3u7vxcgezlcek7ymzyy6be/actions"
          }
      }
    }
    )
  end

  def failed_void_response
    %(
    )
  end

  def invalid_json_response
    %(
    {
      "id": "pay_123",
    )
  end

  def error_code_response
    %(
      {
        "request_id": "e5a3ce6f-a4e9-4445-9ec7-e5975e9a6213","error_type": "request_invalid","error_codes": ["card_expired"]
      }
    )
  end

  def error_type_without_error_codes_response
    %(
      {
        "request_id": "e5a3ce6f-a4e9-4445-9ec7-e5975e9a6213","error_type": "request_invalid"
      }
    )
  end

  def error_4xx_response
    mock_response = Net::HTTPUnauthorized.new('1.1', '401', 'Unauthorized')
    mock_response.stubs(:body).returns('')

    ActiveMerchant::ResponseError.new(mock_response)
  end

  def successful_verify_payment_response
    %(
      {"id":"pay_tkvif5mf54eerhd3ysuawfcnt4","requested_on":"2019-08-14T18:13:54Z","source":{"id":"src_lot2ch4ygk3ehi4fugxmk7r2di","type":"card","expiry_month":12,"expiry_year":2020,"name":"Jane Doe","scheme":"Visa","last4":"0907","fingerprint":"E4048195442B0059D73FD47F6E1961A02CD085B0B34B7703CE4A93750DB5A0A1","bin":"457382","avs_check":"S","cvv_check":"Y"},"amount":100,"currency":"USD","payment_type":"Regular","reference":"Dvy8EMaEphrMWolKsLVHcUqPsyx","status":"Authorized","approved":true,"3ds":{"downgraded":false,"enrolled":"Y","authentication_response":"Y","cryptogram":"ce49b5c1-5d3c-4864-bd16-2a8c","xid":"95202312-f034-48b4-b9b2-54254a2b49fb","version":"2.1.0"},"risk":{"flagged":false},"customer":{"id":"cus_zt5pspdtkypuvifj7g6roy7p6y","name":"Jane Doe"},"billing_descriptor":{"name":"","city":"London"},"payment_ip":"127.0.0.1","metadata":{"Udf5":"ActiveMerchant"},"eci":"05","scheme_id":"638284745624527","actions":[{"id":"act_tkvif5mf54eerhd3ysuawfcnt4","type":"Authorization","response_code":"10000","response_summary":"Approved"}],"_links":{"self":{"href":"https://api.sandbox.checkout.com/payments/pay_tkvif5mf54eerhd3ysuawfcnt4"},"actions":{"href":"https://api.sandbox.checkout.com/payments/pay_tkvif5mf54eerhd3ysuawfcnt4/actions"},"capture":{"href":"https://api.sandbox.checkout.com/payments/pay_tkvif5mf54eerhd3ysuawfcnt4/captures"},"void":{"href":"https://api.sandbox.checkout.com/payments/pay_tkvif5mf54eerhd3ysuawfcnt4/voids"}}}
    )
  end

  def succesful_token_response
    %({"type":"card","token":"tok_267wy4hwrpietkmbbp5iswwhvm","expires_on":"2023-01-03T20:18:49.0006481Z","expiry_month":6,"expiry_year":2025,"name":"Longbob Longsen","scheme":"VISA","last4":"4242","bin":"424242","card_type":"CREDIT","card_category":"CONSUMER","issuer_country":"GB","product_id":"F","product_type":"Visa Classic"})
  end

  def failed_verify_payment_response
    %(
      {"id":"pay_xrwmaqlar73uhjtyoghc7bspa4","requested_on":"2019-08-14T18:32:50Z","source":{"type":"card","expiry_month":12,"expiry_year":2020,"name":"Jane Doe","scheme":"Visa","last4":"7863","fingerprint":"DC20145B78E242C561A892B83CB64471729D7A5063E5A5B341035713B8FDEC92","bin":"453962"},"amount":100,"currency":"USD","payment_type":"Regular","reference":"EuyOZtgt8KI4tolEH8lqxCclWqz","status":"Declined","approved":false,"3ds":{"downgraded":false,"enrolled":"Y","version":"2.1.0"},"risk":{"flagged":false},"customer":{"id":"cus_bb4b7eu35sde7o33fq2xchv7oq","name":"Jane Doe"},"payment_ip":"127.0.0.1","metadata":{"Udf5":"ActiveMerchant"},"_links":{"self":{"href":"https://api.sandbox.checkout.com/payments/pay_xrwmaqlar73uhjtyoghc7bspa4"},"actions":{"href":"https://api.sandbox.checkout.com/payments/pay_xrwmaqlar73uhjtyoghc7bspa4/actions"}}}
    )
  end

  def successful_verify_response
    %({"id":"pay_ij6bctwxpzdulm53xyksio7gm4","action_id":"act_ij6bctwxpzdulm53xyksio7gm4","amount":0,"currency":"USD","approved":true,"status":"Card Verified","auth_code":"881790","eci":"05","scheme_id":"305756859646779","response_code":"10000","response_summary":"Approved","risk":{"flagged":false},"source":{"id":"src_nica37p5k7aufhs3rsv2te7xye","type":"card","billing_address":{"address_line1":"456 My Street","address_line2":"Apt 1","city":"Ottawa","state":"ON","zip":"K1C2N6","country":"CA"},"expiry_month":6,"expiry_year":2025,"name":"Longbob Longsen","scheme":"Visa","last4":"4242","fingerprint":"9F3BAD2E48C6C8579F2F5DC0710B7C11A8ACD5072C3363A72579A6FB227D64BE","bin":"424242","card_type":"Credit","card_category":"Consumer","issuer":"JPMORGAN CHASE BANK NA","issuer_country":"US","product_id":"A","product_type":"Visa Traditional","avs_check":"S","cvv_check":"Y","payouts":true,"fast_funds":"d"},"customer":{"id":"cus_r2yb7f2upmsuhm6nbruoqn657y","email":"longbob.longsen@example.com","name":"Longbob Longsen"},"processed_on":"2020-09-18T18:17:45Z","reference":"1","processing":{"acquirer_transaction_id":"4932795322","retrieval_reference_number":"954188232380"},"_links":{"self":{"href":"https://api.sandbox.checkout.com/payments/pay_ij6bctwxpzdulm53xyksio7gm4"},"actions":{"href":"https://api.sandbox.checkout.com/payments/pay_ij6bctwxpzdulm53xyksio7gm4/actions"}}})
  end

  def failed_verify_response
    %({"request_id":"911829c3-519a-47e8-bbc1-17337789fda0","error_type":"request_invalid","error_codes":["card_number_invalid"]})
  end
end
