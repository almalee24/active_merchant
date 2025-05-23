require 'test_helper'

class RemotePinTest < Test::Unit::TestCase
  def setup
    @gateway = PinGateway.new(fixtures(:pin))

    @amount = 100
    @credit_card = credit_card('5520000000000000', year: Time.now.year + 2)
    @visa_credit_card = credit_card('4200000000000000', year: Time.now.year + 3)
    @declined_card = credit_card('4100000000000001')

    @apple_pay_card = network_tokenization_credit_card(
      '4200000000000000',
      month: 12,
      year: Time.now.year + 2,
      source: :apple_pay,
      eci: '05',
      brand: 'visa',
      payment_cryptogram: 'AABBCCDDEEFFGGHH'
    )

    @google_pay_card = network_tokenization_credit_card(
      '4200000000000000',
      month: 12,
      year: Time.now.year + 2,
      source: :google_pay,
      eci: '05',
      brand: 'visa',
      payment_cryptogram: 'AABBCCDDEEFFGGHH'
    )

    @options = {
      email: 'roland@pinpayments.com',
      ip: '203.59.39.62',
      order_id: '1',
      billing_address: address,
      description: "Store Purchase #{DateTime.now.to_i}"
    }

    @additional_options_3ds_passthrough = @options.merge(
      three_d_secure: {
        version: '1.0.2',
        eci: '06',
        cavv: 'AgAAAAAAAIR8CQrXcIhbQAAAAAA',
        xid: 'MDAwMDAwMDAwMDAwMDAwMzIyNzY='
      }
    )

    @additional_options_3ds = @options.merge(
      three_d_secure: {
        enabled: true,
        fallback_ok: true,
        callback_url: 'https://yoursite.com/authentication_complete'
      }
    )
  end

  def test_successful_purchase
    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_success response
    assert_equal true, response.params['response']['captured']
  end

  def test_successful_purchase_with_metadata
    options_with_metadata = {
      metadata: {
        order_id: generate_unique_id,
        purchase_number: generate_unique_id
      }
    }
    response = @gateway.purchase(@amount, @credit_card, @options.merge(options_with_metadata))
    assert_success response
    assert_equal true, response.params['response']['captured']
    assert_equal options_with_metadata[:metadata][:order_id], response.params['response']['metadata']['order_id']
    assert_equal options_with_metadata[:metadata][:purchase_number], response.params['response']['metadata']['purchase_number']
  end

  def test_successful_purchase_with_platform_adjustment
    options_with_platform_adjustment = {
      platform_adjustment: {
        amount: 30,
        currency: 'AUD'
      }
    }
    response = @gateway.purchase(@amount, @credit_card, @options.merge(options_with_platform_adjustment))
    assert_success response
    assert_equal true, response.params['response']['captured']
    assert_equal options_with_platform_adjustment[:platform_adjustment][:amount], response.params['response']['platform_adjustment']['amount']
    assert_equal options_with_platform_adjustment[:platform_adjustment][:currency], response.params['response']['platform_adjustment']['currency']
  end

  def test_successful_purchase_with_reference
    response = @gateway.purchase(@amount, @credit_card, @options.merge(reference: 'statement descriptor'))
    assert_success response
  end

  def test_successful_authorize_and_capture
    authorization = @gateway.authorize(@amount, @credit_card, @options)
    assert_success authorization
    assert_equal false, authorization.params['response']['captured']

    response = @gateway.capture(@amount, authorization.authorization, @options)
    assert_success response
    assert_equal true, response.params['response']['captured']
  end

  def test_successful_authorize_and_capture_with_passthrough_3ds
    authorization = @gateway.authorize(@amount, @credit_card, @additional_options_3ds_passthrough)
    assert_success authorization
    assert_equal false, authorization.params['response']['captured']

    response = @gateway.capture(@amount, authorization.authorization, @options)
    assert_success response
    assert_equal true, response.params['response']['captured']
  end

  def test_successful_authorize_and_capture_with_3ds
    authorization = @gateway.authorize(@amount, @credit_card, @additional_options_3ds)
    assert_success authorization
    assert_equal false, authorization.params['response']['captured']

    response = @gateway.capture(@amount, authorization.authorization, @options)
    assert_success response
    assert_equal true, response.params['response']['captured']
  end

  def test_failed_authorize
    response = @gateway.authorize(@amount, @declined_card, @options)
    assert_failure response
  end

  def test_failed_capture_due_to_invalid_token
    response = @gateway.capture(@amount, 'bogus', @options)
    assert_failure response
  end

  def test_failed_capture_due_to_invalid_amount
    authorization = @gateway.authorize(@amount, @credit_card, @options)
    assert_success authorization
    assert_equal authorization.params['response']['captured'], false

    response = @gateway.capture(@amount - 1, authorization.authorization, @options)
    assert_failure response
    assert_equal 'invalid_capture_amount', response.params['error']
  end

  def test_successful_purchase_without_description
    @options.delete(:description)
    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_success response
  end

  def test_successful_purchase_with_apple_pay
    response = @gateway.purchase(@amount, @apple_pay_card, @options)
    assert_success response
    assert_equal true, response.params['response']['captured']
  end

  def test_successful_purchase_with_google_pay
    response = @gateway.purchase(@amount, @google_pay_card, @options)
    assert_success response
    assert_equal true, response.params['response']['captured']
  end

  def test_unsuccessful_purchase
    response = @gateway.purchase(@amount, @declined_card, @options)
    assert_failure response
  end

  # This is a bit manual as we have to create a working card token as
  # would be returned from Pin.js / the card tokens API which
  # falls outside of active merchant
  def test_store_and_charge_with_pinjs_card_token
    headers = {
      'Content-Type' => 'application/json',
      'Authorization' => "Basic #{Base64.strict_encode64(@gateway.options[:api_key] + ':').strip}"
    }
    # Get a token equivalent to what is returned by Pin.js
    card_attrs = {
      number: @credit_card.number,
      expiry_month: @credit_card.month,
      expiry_year: @credit_card.year,
      cvc: @credit_card.verification_value,
      name: "#{@credit_card.first_name} #{@credit_card.last_name}",
      address_line1: '42 Sevenoaks St',
      address_city: 'Lathlain',
      address_postcode: '6454',
      address_start: 'WA',
      address_country: 'Australia'
    }
    url = @gateway.test_url + '/cards'

    body = JSON.parse(@gateway.ssl_post(url, card_attrs.to_json, headers))

    card_token = body['response']['token']

    store = @gateway.store(card_token, @options)
    assert_success store
    assert_not_nil store.authorization

    purchase = @gateway.purchase(@amount, card_token, @options)
    assert_success purchase
    assert_not_nil purchase.authorization
  end

  def test_store_and_customer_token_charge
    response = @gateway.store(@credit_card, @options)
    assert_success response
    assert_not_nil response.authorization

    token = response.authorization

    assert response1 = @gateway.purchase(@amount, token, @options)
    assert_success response1

    assert response2 = @gateway.purchase(@amount, token, @options)
    assert_success response2
    assert_not_equal response1.authorization, response2.authorization
  end

  def test_store_and_update
    response = @gateway.store(@credit_card, @options)
    assert_success response
    assert_not_nil response.authorization
    assert_equal @credit_card.year, response.params['response']['card']['expiry_year']

    response = @gateway.update(response.authorization, @visa_credit_card, address:)
    assert_success response
    assert_not_nil response.authorization
    assert_equal @visa_credit_card.year, response.params['response']['card']['expiry_year']
  end

  def test_store_and_unstore
    response = @gateway.store(@credit_card, @options)
    assert_success response
    assert_not_nil response.authorization

    response = @gateway.unstore(response.authorization)
    assert_success response
  end

  def test_refund
    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_success response
    assert_not_nil response.authorization

    token = response.authorization

    response = @gateway.refund(@amount, token, @options)
    assert_success response
    assert_not_nil response.authorization
  end

  def test_failed_refund
    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_success response
    assert_not_nil response.authorization

    token = response.authorization

    response = @gateway.refund(@amount, token.reverse, @options)
    assert_failure response
  end

  def test_successful_void
    authorization = @gateway.authorize(@amount, @credit_card, @options)
    assert_success authorization

    assert void = @gateway.void(authorization.authorization, @options)
    assert_success void
  end

  def test_failed_void
    authorization = @gateway.authorize(@amount, @credit_card, @options)
    assert_success authorization

    assert void = @gateway.void(authorization.authorization, @options)
    assert_success void

    assert already_voided = @gateway.void(authorization.authorization, @options)
    assert_failure already_voided
  end

  def test_invalid_login
    gateway = PinGateway.new(api_key: '')
    response = gateway.purchase(@amount, @credit_card, @options)
    assert_failure response
  end

  def test_transcript_scrubbing
    transcript = capture_transcript(@gateway) do
      @gateway.purchase(@amount, @credit_card, @options)
    end
    clean_transcript = @gateway.scrub(transcript)

    assert_scrubbed(@credit_card.number, clean_transcript)
    assert_scrubbed(@credit_card.verification_value.to_s, clean_transcript)
  end

  def test_transcript_scrubbing_with_apple_pay
    transcript = capture_transcript(@gateway) do
      @gateway.purchase(@amount, @apple_pay_card, @options)
    end
    clean_transcript = @gateway.scrub(transcript)

    assert_scrubbed(@apple_pay_card.number, clean_transcript)
    assert_scrubbed(@apple_pay_card.verification_value.to_s, clean_transcript)
    assert_scrubbed(@apple_pay_card.payment_cryptogram, clean_transcript)
  end
end
