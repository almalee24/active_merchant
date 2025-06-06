require 'test_helper'

class RemoteOrbitalGatewayTest < Test::Unit::TestCase
  def setup
    Base.mode = :test
    @gateway = ActiveMerchant::Billing::OrbitalGateway.new(fixtures(:orbital_gateway))
    @echeck_gateway = ActiveMerchant::Billing::OrbitalGateway.new(fixtures(:orbital_asv_aoa_gateway))
    @three_ds_gateway = ActiveMerchant::Billing::OrbitalGateway.new(fixtures(:orbital_3ds_gateway))
    @tpv_orbital_gateway = ActiveMerchant::Billing::OrbitalGateway.new(fixtures(:orbital_tpv_gateway))
    @amount = 100
    @google_pay_amount = 10000
    @credit_card = credit_card('4556761029983886')
    @mastercard_card_tpv = credit_card('2521000000000006')
    @declined_card = credit_card('4000300011112220')
    # Electronic Check object with test credentials of saving account
    @echeck = check(account_number: '072403004', account_type: 'savings', routing_number: '072403004')
    @google_pay_card = network_tokenization_credit_card(
      '4777777777777778',
      payment_cryptogram: 'BwAQCFVQdwEAABNZI1B3EGLyGC8=',
      verification_value: '987',
      source: :google_pay,
      brand: 'visa',
      eci: '5'
    )

    @options = {
      order_id: generate_unique_id,
      address:,
      merchant_id: 'merchant1234'
    }

    @cards = {
      visa: '4556761029983886',
      mc: '5454545454545454',
      amex: '371449635398431',
      ds: '6011000995500000',
      diners: '36438999960016',
      jcb: '3566002020140006'
    }

    @level_2_options = {
      tax_indicator: '1',
      tax: '75',
      advice_addendum_1: 'taa1 - test',
      advice_addendum_2: 'taa2 - test',
      advice_addendum_3: 'taa3 - test',
      advice_addendum_4: 'taa4 - test',
      purchase_order: '123abc',
      name: address[:name],
      address1: address[:address1],
      address2: address[:address2],
      city: address[:city],
      state: address[:state],
      zip: address[:zip],
      requestor_name: 'ArtVandelay123',
      total_tax_amount: '75',
      national_tax: '625',
      pst_tax_reg_number: '8675309',
      customer_vat_reg_number: '1234567890',
      merchant_vat_reg_number: '987654321',
      commodity_code: 'SUMM',
      local_tax_rate: '6250'
    }

    @level_3_options_visa = {
      freight_amount: 1,
      duty_amount: 1,
      ship_from_zip: 27604,
      dest_country: 'USA',
      discount_amount: 1,
      vat_tax: 1,
      vat_rate: 25,
      invoice_discount_treatment: 1,
      tax_treatment: 1,
      ship_vat_rate: 10,
      unique_vat_invoice_ref: 'ABC123'
    }

    @level_2_options_master = {
      freight_amount: 1,
      duty_amount: 1,
      ship_from_zip: 27604,
      dest_country: 'USA',
      alt_tax: 1,
      alt_ind: 25
    }

    @line_items_visa = [
      {
        desc: 'another item',
        prod_cd: generate_unique_id[0, 11],
        qty: 1,
        u_o_m: 'LBR',
        tax_amt: 250,
        tax_rate: 10000,
        line_tot: 2500,
        disc: 250,
        comm_cd: '00584',
        unit_cost: 2500,
        gross_net: 'Y',
        tax_type: 'sale',
        debit_ind: 'C'
      },
      {
        desc: 'something else',
        prod_cd: generate_unique_id[0, 11],
        qty: 1,
        u_o_m: 'LBR',
        tax_amt: 125,
        tax_rate: 5000,
        line_tot: 2500,
        disc: 250,
        comm_cd: '00584',
        unit_cost: 250000,
        gross_net: 'Y',
        tax_type: 'sale',
        debit_ind: 'C'
      }
    ]

    @test_suite = [
      { card: :visa, AVSzip: 11111, CVD: 111,  amount: 3000 },
      { card: :visa, AVSzip: 33333, CVD: nil,  amount: 3801 },
      { card: :mc,   AVSzip: 44444, CVD: nil,  amount: 4100 },
      { card: :mc,   AVSzip: 88888, CVD: 666,  amount: 1102 },
      { card: :amex, AVSzip: 55555, CVD: nil,  amount: 105500 },
      { card: :amex, AVSzip: 66666, CVD: 2222, amount: 7500 },
      { card: :ds,   AVSzip: 77777, CVD: nil,  amount: 1000 },
      { card: :ds,   AVSzip: 88888, CVD: 444,  amount: 6303 },
      { card: :jcb,  AVSzip: 33333, CVD: nil,  amount: 2900 }
    ]
  end

  def test_successful_purchase
    assert response = @gateway.purchase(@amount, @credit_card, @options)
    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_purchase_with_override
    assert response = @gateway.purchase(@amount, @credit_card, @options.merge(override_exp_date: '0429'))
    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_purchase_with_soft_descriptor_hash
    options = @options.merge(
      soft_descriptors: {
        merchant_name: 'Merch',
        product_description: 'Description',
        merchant_email: 'email@example'
      }
    )
    assert response = @gateway.purchase(@amount, @credit_card, options)
    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_purchase_with_card_indicators
    options = @options.merge(
      card_indicators: 'y'
    )
    assert response = @gateway.purchase(@amount, @credit_card, options)
    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_purchase_with_card_indicators_and_line_items
    options = @options.merge(
      line_items: @line_items,
      card_indicators: 'y'
    )
    assert response = @gateway.purchase(@amount, @credit_card, options)
    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_purchase_with_level_2_data
    response = @gateway.purchase(@amount, @credit_card, @options.merge(level_2_data: @level_2_options))

    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_purchase_with_level_3_data
    response = @gateway.purchase(@amount, @credit_card, @options.merge(level_2_data: @level_2_options, level_3_data: @level_3_options_visa, line_items: @line_items_visa))

    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_purchase_with_visa_network_tokenization_credit_card_with_eci
    network_card = network_tokenization_credit_card(
      '4788250000028291',
      payment_cryptogram: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      transaction_id: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      verification_value: '111',
      brand: 'visa',
      eci: '5'
    )
    # Ensure that soft descriptor fields don't conflict with network token data in schema
    options = @options.merge(
      soft_descriptors: {
        merchant_name: 'Merch',
        product_description: 'Description',
        merchant_email: 'email@example'
      }
    )

    assert response = @gateway.purchase(3000, network_card, options)
    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  def test_successful_purchase_with_master_card_network_tokenization_credit_card
    network_card = network_tokenization_credit_card(
      '4788250000028291',
      payment_cryptogram: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      transaction_id: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      verification_value: '111',
      brand: 'master'
    )
    assert response = @gateway.purchase(3000, network_card, @options)
    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  def test_successful_purchase_with_sca_recurring_master_card
    cc = credit_card('5555555555554444', first_name: 'Joe', last_name: 'Smith',
                     month: '12', year: '2022', brand: 'master', verification_value: '999')
    options_local = {
      three_d_secure: {
        eci: '7',
        xid: 'TESTXID',
        cavv: 'AAAEEEDDDSSSAAA2243234',
        ds_transaction_id: '97267598FAE648F28083C23433990FBC',
        version: '2.2.0'
      },
      sca_recurring: 'Y'
    }

    assert response = @three_ds_gateway.purchase(100, cc, @options.merge(options_local))

    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  def test_successful_purchase_with_sca_merchant_initiated_master_card
    cc = credit_card('5555555555554444', first_name: 'Joe', last_name: 'Smith',
                     month: '12', year: '2022', brand: 'master', verification_value: '999')
    options_local = {
      three_d_secure: {
        eci: '7',
        xid: 'TESTXID',
        cavv: 'AAAEEEDDDSSSAAA2243234',
        ds_transaction_id: '97267598FAE648F28083C23433990FBC',
        version: '2.2.0'
      },
      sca_merchant_initiated: 'Y'
    }

    assert response = @three_ds_gateway.purchase(100, cc, @options.merge(options_local))

    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  def test_successful_purchase_with_american_express_network_tokenization_credit_card
    network_card = network_tokenization_credit_card(
      '4788250000028291',
      payment_cryptogram: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      transaction_id: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      verification_value: '111',
      brand: 'american_express'
    )
    assert response = @gateway.purchase(3000, network_card, @options)
    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  def test_successful_purchase_with_discover_network_tokenization_credit_card
    network_card = network_tokenization_credit_card(
      '4788250000028291',
      payment_cryptogram: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      transaction_id: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      verification_value: '111',
      brand: 'discover'
    )
    assert response = @gateway.purchase(3000, network_card, @options)
    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  def test_successful_purchase_with_echeck
    assert response = @echeck_gateway.purchase(20, @echeck, @options)
    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  def test_successful_purchase_with_echeck_having_written_authorization
    @options[:auth_method] = 'W'
    assert response = @echeck_gateway.purchase(20, @echeck, @options)
    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  def test_successful_purchase_with_echeck_having_internet_authorization
    @options[:auth_method] = 'I'
    assert response = @echeck_gateway.purchase(20, @echeck, @options)
    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  def test_successful_purchase_with_echeck_having_telephonic_authorization
    @options[:auth_method] = 'T'
    assert response = @echeck_gateway.purchase(20, @echeck, @options)
    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  def test_successful_purchase_with_echeck_having_arc_authorization
    test_check = check(account_number: '000000000', account_type: 'checking', routing_number: '072403004')
    assert response = @echeck_gateway.purchase(20, test_check, @options.merge({ auth_method: 'A' }))
    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  def test_failed_missing_serial_for_arc_with_echeck
    assert_raise do
      test_check = { account_type: 'savings', routing_number: '072403004' }
      @echeck_gateway.purchase(20, test_check, @options.merge({ auth_method: 'A' }))
    end
  end

  def test_successful_purchase_with_echeck_having_pop_authorization
    test_check = check(account_number: '000000000', account_type: 'savings', routing_number: '072403004')
    assert response = @echeck_gateway.purchase(20, test_check, @options.merge({ auth_method: 'P', terminal_city: 'CO', terminal_state: 'IL', image_reference_number: '00000' }))
    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  def test_failed_missing_serial_for_pop_with_echeck
    assert_raise do
      test_check = { account_type: 'savings', routing_number: '072403004' }
      @echeck_gateway.purchase(20, test_check, @options.merge({ auth_method: 'P' }))
    end
  end

  def test_successful_purchase_with_echeck_on_same_day
    @options[:same_day] = 'Y'
    assert response = @echeck_gateway.purchase(20, @echeck, @options)
    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  def test_successful_purchase_with_echeck_on_next_day
    @options[:same_day] = 'N'
    assert response = @echeck_gateway.purchase(20, @echeck, @options)
    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  def test_successful_purchase_with_commercial_echeck
    commercial_echeck = check(account_number: '072403004', account_type: 'checking', account_holder_type: 'business', routing_number: '072403004')

    assert response = @echeck_gateway.purchase(20, commercial_echeck, @options)
    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  def test_successful_purchase_with_mit_stored_credentials
    mit_stored_credentials = {
      mit_msg_type: 'MUSE',
      mit_stored_credential_ind: 'Y',
      mit_submitted_transaction_id: 'abcdefg12345678'
    }

    response = @gateway.purchase(@amount, @credit_card, @options.merge(mit_stored_credentials))

    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_purchase_with_cit_stored_credentials
    cit_options = {
      mit_msg_type: 'CUSE',
      mit_stored_credential_ind: 'Y'
    }

    response = @gateway.purchase(@amount, @credit_card, @options.merge(cit_options))

    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_purchase_using_stored_credential_recurring_cit
    initial_options = stored_credential_options(:cardholder, :recurring, :initial)
    assert purchase = @gateway.purchase(@amount, @credit_card, initial_options)
    assert_success purchase
    assert_equal 'Approved', purchase.message
    assert network_transaction_id = purchase.params['mit_received_transaction_id']

    used_options = stored_credential_options(:recurring, :cardholder, id: network_transaction_id)
    assert purchase = @gateway.purchase(@amount, @credit_card, used_options)
    assert_success purchase
    assert_equal 'Approved', purchase.message
  end

  def test_purchase_using_stored_credential_recurring_mit
    initial_options = stored_credential_options(:merchant, :recurring, :initial)
    assert purchase = @gateway.purchase(@amount, @credit_card, initial_options)
    assert_success purchase
    assert_equal 'Approved', purchase.message
    assert network_transaction_id = purchase.params['mit_received_transaction_id']

    used_options = stored_credential_options(:recurring, :merchant, id: network_transaction_id)
    assert purchase = @gateway.purchase(@amount, @credit_card, used_options)
    assert_success purchase
    assert_equal 'Approved', purchase.message
  end

  def test_successful_purchase_with_overridden_normalized_stored_credentials
    stored_credential = {
      stored_credential: {
        initial_transaction: false,
        initiator: 'merchant',
        reason_type: 'unscheduled',
        network_transaction_id: 'abcdefg12345678'
      },
      mit_msg_type: 'MRSB'
    }

    response = @gateway.purchase(@amount, @credit_card, @options.merge(stored_credential))

    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_purchase_with_google_pay
    response = @gateway.purchase(@google_pay_amount, @google_pay_card, @options)
    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_force_capture_with_echeck
    @options[:force_capture] = true
    assert response = @echeck_gateway.purchase(@amount, @echeck, @options)
    assert_success response
    assert_match 'APPROVAL', response.message
    assert_equal 'Approved and Completed', response.params['status_msg']
    assert_false response.authorization.blank?
  end

  def test_failed_force_capture_with_echeck_due_to_invalid_amount
    @options[:force_capture] = true
    assert capture = @echeck_gateway.purchase(-1, @echeck, @options.merge(order_id: '2'))
    assert_failure capture
    assert_equal '801', capture.params['proc_status']
    assert_equal 'Error validating amount. Must be numerical and greater than 0 [-1]', capture.message
  end

  def test_successful_force_capture_with_echeck_prenote_valid_action_code
    @options[:force_capture] = true
    @options[:action_code] = 'W8'
    assert response = @echeck_gateway.authorize(0, @echeck, @options)
    assert_success response
    assert_match 'APPROVAL', response.message
    assert_equal 'Approved and Completed', response.params['status_msg']
    assert_false response.authorization.blank?
  end

  def test_failed_force_capture_with_echeck_prenote_invalid_action_code
    @options[:force_capture] = true
    @options[:action_code] = 'W7'
    assert authorize = @echeck_gateway.authorize(0, @echeck, @options)
    assert_failure authorize
    assert_equal '19784', authorize.params['proc_status']
    assert_equal ' EWS: Invalid Action Code [W7], For Transaction Type [A].', authorize.message
  end

  # Amounts of x.01 will fail
  def test_unsuccessful_purchase
    assert response = @gateway.purchase(101, @declined_card, @options)
    assert_failure response
    assert_equal 'Invalid CC Number', response.message
  end

  def test_authorize_and_capture
    amount = @amount
    assert auth = @gateway.authorize(amount, @credit_card, @options.merge(order_id: '2'))
    assert_success auth
    assert_equal 'Approved', auth.message
    assert auth.authorization
    assert capture = @gateway.capture(amount, auth.authorization, order_id: '2')
    assert_success capture
  end

  def test_successful_authorize_and_capture_with_level_2_data
    auth = @gateway.authorize(@amount, @credit_card, @options.merge(level_2_data: @level_2_options))
    assert_success auth
    assert_equal 'Approved', auth.message

    capture = @gateway.capture(@amount, auth.authorization, @options.merge(level_2_data: @level_2_options))
    assert_success capture
  end

  def test_successful_authorize_and_capture_with_level_3_data
    auth = @gateway.authorize(@amount, @credit_card, @options.merge(level_3_data: @level_3_options))
    assert_success auth
    assert_equal 'Approved', auth.message

    capture = @gateway.capture(@amount, auth.authorization, @options.merge(level_3_data: @level_3_options))
    assert_success capture
  end

  def test_successful_authorize_and_capture_with_echeck
    assert auth = @echeck_gateway.authorize(@amount, @echeck, @options.merge(order_id: '2'))
    assert_success auth
    assert_equal 'Approved', auth.message
    assert auth.authorization
    assert capture = @echeck_gateway.capture(@amount, auth.authorization, order_id: '2')
    assert_success capture
  end

  def test_successful_authorize_and_capture_with_line_items
    auth = @gateway.authorize(@amount, @credit_card, @options.merge(level_2_data: @level_2_options, level_3_data: @level_3_options_visa, line_items: @line_items_visa))
    assert_success auth
    assert_equal 'Approved', auth.message

    capture = @gateway.capture(@amount, auth.authorization, @options.merge(level_2_data: @level_2_options, level_3_data: @level_3_options_visa, line_items: @line_items_visa))
    assert_success capture
  end

  def test_successful_authorize_and_capture_with_google_pay
    auth = @gateway.authorize(@amount, @google_pay_card, @options)
    assert_success auth
    assert_equal 'Approved', auth.message

    capture = @gateway.capture(@amount, auth.authorization, @options)
    assert_success capture
  end

  def test_failed_authorize_with_echeck_due_to_invalid_amount
    assert auth = @echeck_gateway.authorize(-1, @echeck, @options.merge(order_id: '2'))
    assert_failure auth
    assert_equal '885', auth.params['proc_status']
    assert_equal 'Error validating amount. Must be numeric, equal to zero or greater [-1]', auth.message
  end

  def test_authorize_and_void
    assert auth = @gateway.authorize(@amount, @credit_card, @options.merge(order_id: '2'))
    assert_success auth
    assert_equal 'Approved', auth.message
    assert auth.authorization
    assert void = @gateway.void(auth.authorization, order_id: '2')
    assert_success void
  end

  def test_successful_authorize_and_void_with_echeck
    assert auth = @echeck_gateway.authorize(@amount, @echeck, @options.merge(order_id: '2'))
    assert_success auth
    assert_equal 'Approved', auth.message
    assert auth.authorization
    assert void = @echeck_gateway.void(auth.authorization, order_id: '2')
    assert_success void
  end

  def test_authorize_and_void_using_google_pay
    assert auth = @gateway.authorize(@amount, @google_pay_card, @options)
    assert_success auth
    assert_equal 'Approved', auth.message

    assert auth.authorization
    assert void = @gateway.void(auth.authorization)
    assert_success void
  end

  def test_successful_refund
    amount = @amount
    assert response = @gateway.purchase(amount, @credit_card, @options)
    assert_success response
    assert response.authorization
    assert refund = @gateway.refund(amount, response.authorization, @options)
    assert_success refund
  end

  def test_successful_refund_with_payment_source
    amount = @amount
    assert response = @gateway.purchase(amount, @credit_card, @options)
    assert_success response
    assert response.authorization

    assert refund = @gateway.refund(amount, '', @options.merge({ payment_method: @credit_card }))
    assert_success refund
  end

  def test_failed_refund
    assert refund = @gateway.refund(@amount, '123;123', @options)
    assert_failure refund
    assert_equal '881', refund.params['proc_status']
  end

  def test_successful_refund_with_google_pay
    auth = @gateway.authorize(@amount, @google_pay_card, @options)
    assert_success auth
    assert_equal 'Approved', auth.message

    capture = @gateway.capture(@amount, auth.authorization, @options)
    assert_success capture

    assert capture.authorization
    assert refund = @gateway.refund(@amount, capture.authorization, @options)
    assert_success refund
  end

  def test_successful_refund_with_echeck
    assert response = @echeck_gateway.purchase(@amount, @echeck, @options)
    assert_success response
    assert response.authorization
    assert refund = @echeck_gateway.refund(@amount, response.authorization, @options)
    assert_success refund
  end

  def test_failed_refund_with_echeck_due_to_invalid_authorization
    assert refund = @echeck_gateway.refund(@amount, '123;123', @options)
    assert_failure refund
    assert_equal 'The LIDM you supplied (3F3F3F) does not match with any existing transaction', refund.message
    assert_equal '881', refund.params['proc_status']
  end

  def test_successful_refund_with_level_2_data
    amount = @amount
    assert response = @gateway.purchase(amount, @credit_card, @options.merge(level_2_data: @level_2_options))
    assert_success response
    assert response.authorization
    assert refund = @gateway.refund(amount, response.authorization, @options.merge(level_2_data: @level_2_options))
    assert_success refund
  end

  def test_successful_credit
    payment_method = credit_card('5454545454545454')
    assert response = @gateway.credit(@amount, payment_method, @options)
    assert_success response
  end

  def test_failed_capture
    assert response = @gateway.capture(@amount, '')
    assert_failure response
    assert_equal 'Bad data error', response.message
  end

  def test_authorize_sends_with_retry
    assert auth = @echeck_gateway.authorize(@amount, @credit_card, @options.merge(order_id: '4', retry_logic: 'true', trace_number: '989898'))
    assert_success auth
    assert_equal 'Approved', auth.message
  end

  def test_authorize_sends_with_payment_delivery
    assert auth = @echeck_gateway.authorize(@amount, @echeck, @options.merge(order_id: '4', payment_delivery: 'A'))
    assert_success auth
    assert_equal 'Approved', auth.message
  end

  def test_default_payment_delivery_with_no_payment_delivery_sent
    transcript = capture_transcript(@echeck_gateway) do
      response = @echeck_gateway.authorize(@amount, @echeck, @options.merge(order_id: '4'))
      assert_equal '1', response.params['approval_status']
      assert_equal '00', response.params['resp_code']
    end

    assert_match(/<BankPmtDelv>B/, transcript)
    assert_match(/<MessageType>A/, transcript)
  end

  def test_sending_echeck_adds_ecp_details_for_refund
    assert auth = @echeck_gateway.authorize(@amount, @echeck, @options.merge(order_id: '2'))
    assert_success auth
    assert_equal 'Approved', auth.message

    capture = @echeck_gateway.capture(@amount, auth.authorization, @options)
    assert_success capture

    transcript = capture_transcript(@echeck_gateway) do
      refund = @echeck_gateway.refund(@amount, capture.authorization, @options.merge(payment_method: @echeck, action_code: 'W6', auth_method: 'I'))
      assert_success refund
      assert_equal '1', refund.params['approval_status']
    end

    assert_match(/<ECPActionCode>W6/, transcript)
    assert_match(/<ECPAuthMethod>I/, transcript)
    assert_match(/<MessageType>R/, transcript)
  end

  def test_sending_credit_card_performs_correct_refund
    assert auth = @echeck_gateway.authorize(@amount, @credit_card, @options.merge(order_id: '2'))
    assert_success auth
    assert_equal 'Approved', auth.message

    capture = @echeck_gateway.capture(@amount, auth.authorization, @options)
    assert_success capture

    refund = @echeck_gateway.refund(@amount, capture.authorization, @options)
    assert_success refund
  end

  def test_echeck_purchase_with_address_responds_with_name
    transcript = capture_transcript(@echeck_gateway) do
      response = @echeck_gateway.authorize(@amount, @echeck, @options.merge(order_id: '2'))
      assert_equal '00', response.params['resp_code']
      assert_equal 'Approved', response.params['status_msg']
    end

    assert_match(/<AVSname>Jim Smith/, transcript)
  end

  def test_echeck_purchase_with_no_address_responds_with_name
    test_check_no_address = check(name: 'Test McTest')

    transcript = capture_transcript(@echeck_gateway) do
      response = @echeck_gateway.authorize(@amount, test_check_no_address, @options.merge(order_id: '2', address: nil, billing_address: nil))
      assert_equal '00', response.params['resp_code']
      assert_equal 'Approved', response.params['status_msg']
    end

    assert_match(/<AVSname>Test McTest/, transcript)
  end

  def test_credit_purchase_with_address_responds_with_name
    transcript = capture_transcript(@gateway) do
      response = @gateway.authorize(@amount, @credit_card, @options.merge(order_id: '2'))
      assert_equal '00', response.params['resp_code']
      assert_equal 'Approved', response.params['status_msg']
    end

    assert_match(/<AVSname>Longbob Longsen/, transcript)
  end

  def test_truncates_and_removes_accents_from_name
    truncated_name = 'Jose Maria Lopez Garc'
    credit_card = credit_card('4556761029983886', first_name: ':-) José María', last_name: '😀López García')

    transcript = capture_transcript(@gateway) do
      response = @gateway.authorize(@amount, credit_card, @options)
      assert_success response
    end

    assert_match(/<AVSname>#{truncated_name}/, transcript)
  end

  def test_truncates_and_removes_accents_from_name_when_pm_is_a_check
    truncated_name = 'Jose Maria Lopez Garc'
    check = check(name: ':) José María López García')

    transcript = capture_transcript(@echeck_gateway) do
      response = @echeck_gateway.authorize(@amount, check, @options)
      assert_success response
    end

    assert_match(/<AVSname>#{truncated_name}/, transcript)
  end

  def test_credit_purchase_with_no_address_responds_with_no_name
    response = @gateway.authorize(@amount, @credit_card, @options.merge(order_id: '2', address: nil, billing_address: nil))
    assert_equal '00', response.params['resp_code']
    assert_equal 'Approved', response.params['status_msg']
  end

  # == Certification Tests

  # ==== Section A
  def test_auth_only_transactions
    for suite in @test_suite do
      amount = suite[:amount]
      card = credit_card(@cards[suite[:card]], verification_value: suite[:CVD])
      @options[:address][:zip] = suite[:AVSzip]
      assert response = @gateway.authorize(amount, card, @options)
      assert_kind_of Response, response

      # Makes it easier to fill in cert sheet if you print these to the command line
      # puts "Auth/Resp Code => " + (response.params["auth_code"] || response.params["resp_code"])
      # puts "AVS Resp => " + response.params["avs_resp_code"]
      # puts "CVD Resp => " + response.params["cvv2_resp_code"]
      # puts "TxRefNum => " + response.params["tx_ref_num"]
      # puts
    end
  end

  # ==== Section B
  def test_auth_capture_transactions
    for suite in @test_suite do
      amount = suite[:amount]
      card = credit_card(@cards[suite[:card]], verification_value: suite[:CVD])
      options = @options; options[:address][:zip] = suite[:AVSzip]
      assert response = @gateway.purchase(amount, card, options)
      assert_kind_of Response, response

      # Makes it easier to fill in cert sheet if you print these to the command line
      # puts "Auth/Resp Code => " + (response.params["auth_code"] || response.params["resp_code"])
      # puts "AVS Resp => " + response.params["avs_resp_code"]
      # puts "CVD Resp => " + response.params["cvv2_resp_code"]
      # puts "TxRefNum => " + response.params["tx_ref_num"]
      # puts
    end
  end

  # ==== Section C
  def test_mark_for_capture_transactions
    [[:visa, 3000], [:mc, 4100], [:amex, 105500], [:ds, 1000], [:jcb, 2900]].each do |suite|
      amount = suite[1]
      card = credit_card(@cards[suite[0]])
      assert auth_response = @gateway.authorize(amount, card, @options)
      assert capt_response = @gateway.capture(amount, auth_response.authorization)
      assert_kind_of Response, capt_response

      # Makes it easier to fill in cert sheet if you print these to the command line
      # puts "Auth/Resp Code => " + (auth_response.params["auth_code"] || auth_response.params["resp_code"])
      # puts "TxRefNum => " + capt_response.params["tx_ref_num"]
      # puts
    end
  end

  # ==== Section D
  def test_refund_transactions
    [[:visa, 1200], [:mc, 1100], [:amex, 105500], [:ds, 1000], [:jcb, 2900]].each do |suite|
      amount = suite[1]
      card = credit_card(@cards[suite[0]])
      assert purchase_response = @gateway.purchase(amount, card, @options)
      assert refund_response = @gateway.refund(amount, purchase_response.authorization, @options)
      assert_kind_of Response, refund_response

      # Makes it easier to fill in cert sheet if you print these to the command line
      # puts "Auth/Resp Code => " + (purchase_response.params["auth_code"] || purchase_response.params["resp_code"])
      # puts "TxRefNum => " + credit_response.params["tx_ref_num"]
      # puts
    end
  end

  # ==== Section F
  def test_void_transactions
    [3000, 105500, 2900].each do |amount|
      assert auth_response = @gateway.authorize(amount, @credit_card, @options)
      assert void_response = @gateway.void(auth_response.authorization, @options.merge(transaction_index: 1))
      assert_kind_of Response, void_response

      # Makes it easier to fill in cert sheet if you print these to the command line
      # puts "TxRefNum => " + void_response.params["tx_ref_num"]
      # puts
    end
  end

  def test_successful_verify
    response = @gateway.verify(@credit_card, @options)
    assert_success response
    assert_equal 'No reason to decline', response.message
  end

  def test_successful_store
    response = @tpv_orbital_gateway.store(@mastercard_card_tpv, @options)
    assert_success response
    assert_equal response.authorization.split(';').last, @tpv_orbital_gateway.send(:expiry_date, @mastercard_card_tpv)
    assert_false response.params['safetech_token'].blank?
  end

  def test_successful_purchase_stored_token
    store = @tpv_orbital_gateway.store(@credit_card, @options)
    assert_success store
    assert_equal store.authorization.split(';').last, @tpv_orbital_gateway.send(:expiry_date, @credit_card)

    response = @tpv_orbital_gateway.purchase(@amount, store.authorization, @options)
    assert_success response
    assert_equal response.params['card_brand'], 'VI'
  end

  def test_successful_authorize_stored_token
    store = @tpv_orbital_gateway.store(@credit_card, @options)
    assert_success store
    auth = @tpv_orbital_gateway.authorize(29, store.authorization, @options)
    assert_success auth
  end

  def test_successful_authorize_stored_token_mastercard
    store = @tpv_orbital_gateway.store(@mastercard_card_tpv, @options)
    assert_success store
    assert_equal store.authorization.split(';').last, @tpv_orbital_gateway.send(:expiry_date, @mastercard_card_tpv)

    response = @tpv_orbital_gateway.authorize(29, store.authorization, @options)
    assert_success response
    assert_equal response.params['card_brand'], 'MC'
  end

  def test_failed_authorize_and_capture
    store = @tpv_orbital_gateway.store(@credit_card, @options)
    assert_success store
    authorization = store.authorization.split(';').values_at(2).first
    response = @tpv_orbital_gateway.capture(39, authorization, @options)
    assert_failure response
    assert_equal response.params['status_msg'], "The LIDM you supplied (#{authorization}) does not match with any existing transaction"
  end

  def test_successful_authorize_and_capture_with_stored_token
    store = @tpv_orbital_gateway.store(@mastercard_card_tpv, @options)
    assert_success store
    assert_equal store.authorization.split(';').last, @tpv_orbital_gateway.send(:expiry_date, @mastercard_card_tpv)

    auth = @tpv_orbital_gateway.authorize(28, store.authorization, @options)
    assert_success auth
    assert_equal auth.params['card_brand'], 'MC'
    response = @tpv_orbital_gateway.capture(28, auth.authorization, @options)
    assert_success response
  end

  def test_successful_authorize_with_stored_token_and_refund
    store = @tpv_orbital_gateway.store(@mastercard_card_tpv, @options)
    assert_success store
    auth = @tpv_orbital_gateway.authorize(38, store.authorization, @options)
    assert_success auth
    response = @tpv_orbital_gateway.refund(38, auth.authorization, @options)
    assert_success response
  end

  def test_failed_refund_wrong_token
    store = @tpv_orbital_gateway.store(@mastercard_card_tpv, @options)
    assert_success store
    auth = @tpv_orbital_gateway.authorize(38, store.authorization, @options)
    assert_success auth
    authorization = store.authorization.split(';').values_at(2).first
    response = @tpv_orbital_gateway.refund(38, authorization, @options)
    assert_failure response
    assert_equal response.params['status_msg'], "The LIDM you supplied (#{authorization}) does not match with any existing transaction"
  end

  def test_successful_purchase_with_stored_token_and_refund
    store = @tpv_orbital_gateway.store(@mastercard_card_tpv, @options)
    assert_success store
    purchase = @tpv_orbital_gateway.purchase(38, store.authorization, @options)
    assert_success purchase
    response = @tpv_orbital_gateway.refund(38, purchase.authorization, @options)
    assert_success response
  end

  def test_successful_purchase_without_store
    response = @tpv_orbital_gateway.purchase(@amount, @credit_card, @options)
    assert_success response
    assert_equal response.params['safetech_token'], nil
  end

  def test_failed_purchase_with_stored_token
    auth = @tpv_orbital_gateway.authorize(@amount, @credit_card, @options.merge(store: true))
    assert_success auth
    options = @options.merge!(card_brand: 'VI')
    response = @tpv_orbital_gateway.purchase(@amount, nil, options)
    assert_failure response
    assert_equal response.params['status_msg'], 'Error validating card/account number range'
  end

  def test_successful_different_cards
    @credit_card.brand = 'master'
    response = @gateway.verify(@credit_card, @options)
    assert_success response
    assert_equal 'No reason to decline', response.message
  end

  def test_successful_verify_with_discover_brand
    @credit_card.brand = 'discover'
    response = @gateway.verify(@credit_card, @options)
    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_unsuccessful_verify_with_invalid_discover_card
    @declined_card.brand = 'discover'
    response = @gateway.verify(@declined_card, @options)
    assert_failure response
    assert_equal 'Invalid CC Number', response.message
  end

  def test_failed_verify
    response = @gateway.verify(@declined_card, @options)
    assert_failure response
    assert_equal 'Invalid CC Number', response.message
  end

  def test_transcript_scrubbing
    transcript = capture_transcript(@gateway) do
      @gateway.purchase(@amount, @credit_card, @options)
    end
    transcript = @gateway.scrub(transcript)

    assert_scrubbed(@credit_card.number, transcript)
    assert_scrubbed(@credit_card.verification_value, transcript)
    assert_scrubbed(@gateway.options[:password], transcript)
    assert_scrubbed(@gateway.options[:login], transcript)
    assert_scrubbed(@gateway.options[:merchant_id], transcript)
  end

  def test_transcript_scrubbing_profile
    transcript = capture_transcript(@gateway) do
      @gateway.add_customer_profile(@credit_card, @options)
    end
    transcript = @gateway.scrub(transcript)

    assert_scrubbed(@credit_card.number, transcript)
    assert_scrubbed(@credit_card.verification_value, transcript)
    assert_scrubbed(@gateway.options[:password], transcript)
    assert_scrubbed(@gateway.options[:login], transcript)
    assert_scrubbed(@gateway.options[:merchant_id], transcript)
  end

  def test_transcript_scrubbing_echeck
    transcript = capture_transcript(@echeck_gateway) do
      @echeck_gateway.purchase(20, @echeck, @options)
    end
    transcript = @gateway.scrub(transcript)

    assert_scrubbed(@echeck.account_number, transcript)
    assert_scrubbed(@echeck_gateway.options[:password], transcript)
    assert_scrubbed(@echeck_gateway.options[:login], transcript)
    assert_scrubbed(@echeck_gateway.options[:merchant_id], transcript)
  end

  def test_transcript_scrubbing_network_card
    network_card = network_tokenization_credit_card(
      '4788250000028291',
      payment_cryptogram: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      transaction_id: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      verification_value: '111',
      brand: 'visa',
      eci: '5'
    )
    transcript = capture_transcript(@gateway) do
      @gateway.purchase(@amount, network_card, @options)
    end
    transcript = @gateway.scrub(transcript)

    assert_scrubbed(network_card.payment_cryptogram, transcript)
  end

  private

  def stored_credential_options(*args, id: nil)
    @options.merge(order_id: generate_unique_id,
                   stored_credential: stored_credential(*args, id:))
  end
end

class BrandSpecificOrbitalTests < RemoteOrbitalGatewayTest
  # Additional class for a subset of tests that share setup logic.
  # This will run automatically with the rest of the tests in this file,
  # or you can specify individual tests by name as you usually would.
  def setup
    super

    @brand_specific_fixtures = {
      visa: {
        card: {
          number: '4112344112344113',
          verification_value: '411',
          brand: 'visa'
        },
        three_d_secure: {
          eci: '5',
          cavv: 'AAABAIcJIoQDIzAgVAkiAAAAAAA=',
          xid: 'AAABAIcJIoQDIzAgVAkiAAAAAAA='
        },
        address: {
          address1: '55 Forever Ave',
          address2: '',
          city: 'Concord',
          state: 'NH',
          zip: '03301',
          country: 'US'
        }
      },
      master: {
        card: {
          number: '5112345112345114',
          verification_value: '823',
          brand: 'master'
        },
        three_d_secure: {
          eci: '5',
          cavv: 'AAAEEEDDDSSSAAA2243234',
          xid: 'Asju1ljfl86bAAAAAACm9zU6aqY=',
          version: '2.2.0',
          ds_transaction_id: '8dh4htokdf84jrnxyemfiosheuyfjt82jiek'
        },
        address: {
          address1: 'Byway Street',
          address2: '',
          city: 'Portsmouth',
          state: 'MA',
          zip: '67890',
          country: 'US',
          phone: '5555555555'
        }
      },
      american_express: {
        card: {
          number: '371144371144376',
          verification_value: '1234',
          brand: 'american_express'
        },
        three_d_secure: {
          eci: '5',
          cavv: 'AAABBWcSNIdjeUZThmNHAAAAAAA=',
          xid: 'AAABBWcSNIdjeUZThmNHAAAAAAA='
        },
        address: {
          address1: '4 Northeastern Blvd',
          address2: '',
          city: 'Salem',
          state: 'NH',
          zip: '03105',
          country: 'US'
        }
      },
      discover: {
        card: {
          number: '6011016011016011',
          verification_value: '613',
          brand: 'discover'
        },
        three_d_secure: {
          eci: '6',
          cavv: 'Asju1ljfl86bAAAAAACm9zU6aqY=',
          ds_transaction_id: '32b274ee-582d-4232-b20a-363f2acafa5a'
        },
        address: {
          address1: '1 Northeastern Blvd',
          address2: '',
          city: 'Bedford',
          state: 'NH',
          zip: '03109',
          country: 'US'
        }
      }
    }
  end

  def test_successful_3ds_authorization_with_visa
    cc = brand_specific_card(@brand_specific_fixtures[:visa][:card])
    options = brand_specific_3ds_options(@brand_specific_fixtures[:visa])

    assert response = @three_ds_gateway.authorize(100, cc, options)
    assert_success_with_authorization(response)
  end

  def test_successful_3ds_purchase_with_visa
    cc = brand_specific_card(@brand_specific_fixtures[:visa][:card])
    options = brand_specific_3ds_options(@brand_specific_fixtures[:visa])

    assert response = @three_ds_gateway.purchase(100, cc, options)
    assert_success_with_authorization(response)
  end

  def test_successful_3ds_authorization_with_mastercard
    cc = brand_specific_card(@brand_specific_fixtures[:master][:card])
    options = brand_specific_3ds_options(@brand_specific_fixtures[:master])

    assert response = @three_ds_gateway.authorize(100, cc, options)
    assert_success_with_authorization(response)
  end

  def test_succesful_3ds_purchase_with_mastercard
    cc = brand_specific_card(@brand_specific_fixtures[:master][:card])
    options = brand_specific_3ds_options(@brand_specific_fixtures[:master])

    assert response = @three_ds_gateway.purchase(100, cc, options)
    assert_success_with_authorization(response)
  end

  def test_successful_3ds_authorization_with_american_express
    cc = brand_specific_card(@brand_specific_fixtures[:american_express][:card])
    options = brand_specific_3ds_options(@brand_specific_fixtures[:american_express])

    assert response = @three_ds_gateway.authorize(100, cc, options)
    assert_success_with_authorization(response)
  end

  def test_successful_3ds_purchase_with_american_express
    cc = brand_specific_card(@brand_specific_fixtures[:american_express][:card])
    options = brand_specific_3ds_options(@brand_specific_fixtures[:american_express])

    assert response = @three_ds_gateway.purchase(100, cc, options)
    assert_success_with_authorization(response)
  end

  def test_successful_3ds_authorization_with_discover
    cc = brand_specific_card(@brand_specific_fixtures[:discover][:card])
    options = brand_specific_3ds_options(@brand_specific_fixtures[:discover])

    assert response = @three_ds_gateway.authorize(100, cc, options)
    assert_success_with_authorization(response)
  end

  def test_successful_3ds_purchase_with_discover
    cc = brand_specific_card(@brand_specific_fixtures[:discover][:card])
    options = brand_specific_3ds_options(@brand_specific_fixtures[:discover])

    assert response = @three_ds_gateway.purchase(100, cc, options)
    assert_success_with_authorization(response)
  end

  private

  def assert_success_with_authorization(response)
    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  def brand_specific_3ds_options(data)
    @options.merge(
      order_id: '2',
      currency: 'USD',
      three_d_secure: data[:three_d_secure],
      address: data[:address],
      soft_descriptors: {
        merchant_name: 'Merch',
        product_description: 'Description',
        merchant_email: 'email@example'
      }
    )
  end

  def brand_specific_card(card_data)
    credit_card(
      card_data[:number],
      {
        verification_value: card_data[:verification_value],
        brand: card_data[:brand]
      }
    )
  end
end

class TandemOrbitalTests < Test::Unit::TestCase
  # Additional test cases to verify tandem integration
  def setup
    Base.mode = :test
    @tandem_gateway = ActiveMerchant::Billing::OrbitalGateway.new(fixtures(:orbital_tandem_gateway))

    @amount = 100
    @google_pay_amount = 10000
    @credit_card = credit_card('4556761029983886')
    @declined_card = credit_card('4011361100000012')
    @google_pay_card = network_tokenization_credit_card(
      '4777777777777778',
      payment_cryptogram: 'BwAQCFVQdwEAABNZI1B3EGLyGC8=',
      verification_value: '987',
      source: :google_pay,
      brand: 'visa',
      eci: '5'
    )

    @options = {
      order_id: generate_unique_id,
      address:,
      merchant_id: 'merchant1234'
    }

    @level_2_options = {
      tax_indicator: '1',
      tax: '75',
      purchase_order: '123abc',
      zip: address[:zip],
      requestor_name: 'ArtVandelay123',
      total_tax_amount: '75',
      pst_tax_reg_number: '8675309',
      customer_vat_reg_number: '1234567890',
      commodity_code: 'SUMM',
      local_tax_rate: '6250'
    }

    @level_3_options = {
      freight_amount: 1,
      duty_amount: 1,
      ship_from_zip: 27604,
      dest_country: 'USA',
      discount_amount: 1,
      vat_tax: 1,
      vat_rate: 25,
      invoice_discount_treatment: 1,
      tax_treatment: 1,
      ship_vat_rate: 10,
      unique_vat_invoice_ref: 'ABC123'
    }

    @line_items = [
      {
        desc: 'another item',
        prod_cd: generate_unique_id[0, 11],
        qty: 1,
        u_o_m: 'LBR',
        tax_amt: 250,
        tax_rate: 10000,
        comm_cd: '00584',
        unit_cost: 2500,
        gross_net: 'Y',
        tax_type: 'sale',
        debit_ind: 'C'
      },
      {
        desc: 'something else',
        prod_cd: generate_unique_id[0, 11],
        qty: 1,
        u_o_m: 'LBR',
        tax_amt: 125,
        tax_rate: 5000,
        comm_cd: '00584',
        unit_cost: 1000,
        gross_net: 'Y',
        tax_type: 'sale',
        debit_ind: 'C'
      }
    ]
  end

  def test_successful_purchase
    assert response = @tandem_gateway.purchase(@amount, @credit_card, @options)
    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_purchase_with_inr_currency
    assert response = @tandem_gateway.purchase(@amount, @credit_card, @options.merge(currency: 'INR'))
    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_purchase_with_krw_currency
    assert response = @tandem_gateway.purchase(@amount, @credit_card, @options.merge(currency: 'KRW'))
    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_purchase_with_aed_currency
    assert response = @tandem_gateway.purchase(@amount, @credit_card, @options.merge(currency: 'AED'))
    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_purchase_with_soft_descriptor
    options = @options.merge(
      soft_descriptors: {
        merchant_name: 'Merch',
        product_description: 'Description',
        merchant_email: 'email@example'
      }
    )
    assert response = @tandem_gateway.purchase(@amount, @credit_card, options)
    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_purchase_with_level_2_data
    response = @tandem_gateway.purchase(@amount, @credit_card, @options.merge(level_2_data: @level_2_options))

    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_purchase_with_level_2_data_canadian_currency
    response = @tandem_gateway.purchase(@amount, @credit_card, @options.merge(currency: 'CAD', merchant_vat_reg_number: '987654321', national_tax: '625', level_2_data: @level_2_options))

    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_purchase_with_level_3_data
    response = @tandem_gateway.purchase(@amount, @credit_card, @options.merge(level_2_data: @level_2_options, level_3_data: @level_3_options, line_items: @line_items))

    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_purchase_with_visa_network_tokenization_credit_card_with_eci
    network_card = network_tokenization_credit_card(
      '4788250000028291',
      payment_cryptogram: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      transaction_id: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      verification_value: '111',
      brand: 'visa',
      eci: '5'
    )

    assert response = @tandem_gateway.purchase(3000, network_card, @options)
    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  def test_successful_purchase_with_master_card_network_tokenization_credit_card
    network_card = network_tokenization_credit_card(
      '4788250000028291',
      payment_cryptogram: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      transaction_id: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      verification_value: '111',
      brand: 'master'
    )
    assert response = @tandem_gateway.purchase(3000, network_card, @options)
    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  def test_successful_purchase_with_american_express_network_tokenization_credit_card
    network_card = network_tokenization_credit_card(
      '4788250000028291',
      payment_cryptogram: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      transaction_id: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      verification_value: '111',
      brand: 'american_express'
    )
    assert response = @tandem_gateway.purchase(3000, network_card, @options)
    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  def test_successful_purchase_with_discover_network_tokenization_credit_card
    network_card = network_tokenization_credit_card(
      '4788250000028291',
      payment_cryptogram: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      transaction_id: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      verification_value: '111',
      brand: 'discover'
    )
    assert response = @tandem_gateway.purchase(3000, network_card, @options)
    assert_success response
    assert_equal 'Approved', response.message
    assert_false response.authorization.blank?
  end

  # verify stored credential flows in tandem support

  def test_successful_purchase_with_mit_stored_credentials
    mit_stored_credentials = {
      mit_msg_type: 'MUSE',
      mit_stored_credential_ind: 'Y',
      mit_submitted_transaction_id: '111222333444555'
    }

    response = @tandem_gateway.purchase(@amount, @credit_card, @options.merge(mit_stored_credentials))

    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_purchase_with_cit_stored_credentials
    cit_options = {
      mit_msg_type: 'CUSE',
      mit_stored_credential_ind: 'Y'
    }

    response = @tandem_gateway.purchase(@amount, @credit_card, @options.merge(cit_options))

    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_purchase_using_stored_credential_recurring_cit
    initial_options = stored_credential_options(:cardholder, :recurring, :initial)
    assert purchase = @tandem_gateway.purchase(@amount, @credit_card, initial_options)
    assert_success purchase
    assert_equal 'Approved', purchase.message
    assert network_transaction_id = purchase.params['mit_received_transaction_id']

    used_options = stored_credential_options(:recurring, :cardholder, id: network_transaction_id)
    assert purchase = @tandem_gateway.purchase(@amount, @credit_card, used_options)
    assert_success purchase
    assert_equal 'Approved', purchase.message
  end

  def test_purchase_using_stored_credential_recurring_mit
    initial_options = stored_credential_options(:merchant, :recurring, :initial)
    assert purchase = @tandem_gateway.purchase(@amount, @credit_card, initial_options)
    assert_success purchase
    assert_equal 'Approved', purchase.message
    assert network_transaction_id = purchase.params['mit_received_transaction_id']

    used_options = stored_credential_options(:recurring, :merchant, id: network_transaction_id)
    assert purchase = @tandem_gateway.purchase(@amount, @credit_card, used_options)
    assert_success purchase
    assert_equal 'Approved', purchase.message
  end

  def test_successful_purchase_with_overridden_normalized_stored_credentials
    stored_credential = {
      stored_credential: {
        initial_transaction: false,
        initiator: 'merchant',
        reason_type: 'unscheduled',
        network_transaction_id: '111222333444555'
      },
      mit_msg_type: 'MRSB'
    }

    response = @tandem_gateway.purchase(@amount, @credit_card, @options.merge(stored_credential))

    assert_success response
    assert_equal 'Approved', response.message
  end

  # verify google pay transactions on tandem account

  def test_successful_purchase_with_google_pay
    response = @tandem_gateway.purchase(@google_pay_amount, @google_pay_card, @options)
    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_unsuccessful_purchase
    assert response = @tandem_gateway.purchase(101, @declined_card, @options)
    assert_failure response
    assert_match 'AUTH DECLINED', response.message
  end

  def test_authorize_and_capture
    amount = @amount
    assert auth = @tandem_gateway.authorize(amount, @credit_card, @options.merge(order_id: '2'))
    assert_success auth
    assert_equal 'Approved', auth.message
    assert auth.authorization
    assert capture = @tandem_gateway.capture(amount, auth.authorization, order_id: '2')
    assert_success capture
  end

  def test_successful_authorize_and_capture_with_level_2_data
    auth = @tandem_gateway.authorize(@amount, @credit_card, @options.merge(level_2_data: @level_2_options))
    assert_success auth
    assert_equal 'Approved', auth.message

    capture = @tandem_gateway.capture(@amount, auth.authorization, @options.merge(level_2_data: @level_2_options))
    assert_success capture
  end

  def test_successful_authorize_and_capture_with_line_items
    auth = @tandem_gateway.authorize(@amount, @credit_card, @options.merge(level_2_data: @level_2_options, level_3_data: @level_3_options, line_items: @line_items))
    assert_success auth
    assert_equal 'Approved', auth.message

    capture = @tandem_gateway.capture(@amount, auth.authorization, @options.merge(level_2_data: @level_2_options, level_3_data: @level_3_options, line_items: @line_items))
    assert_success capture
  end

  def test_successful_authorize_and_capture_with_google_pay
    auth = @tandem_gateway.authorize(@amount, @google_pay_card, @options)
    assert_success auth
    assert_equal 'Approved', auth.message

    capture = @tandem_gateway.capture(@amount, auth.authorization, @options)
    assert_success capture
  end

  def test_authorize_and_void
    assert auth = @tandem_gateway.authorize(@amount, @credit_card, @options.merge(order_id: '2'))
    assert_success auth
    assert_equal 'Approved', auth.message
    assert auth.authorization
    assert void = @tandem_gateway.void(auth.authorization, order_id: '2')
    assert_success void
  end

  def test_authorize_and_void_using_google_pay
    assert auth = @tandem_gateway.authorize(@amount, @google_pay_card, @options)
    assert_success auth
    assert_equal 'Approved', auth.message

    assert auth.authorization
    assert void = @tandem_gateway.void(auth.authorization)
    assert_success void
  end

  def test_successful_refund
    amount = @amount
    assert response = @tandem_gateway.purchase(amount, @credit_card, @options)
    assert_success response
    assert response.authorization
    assert refund = @tandem_gateway.refund(amount, response.authorization, @options)
    assert_success refund
  end

  def test_failed_refund
    assert refund = @tandem_gateway.refund(@amount, '123;123', @options)
    assert_failure refund
    assert_equal '881', refund.params['proc_status']
  end

  def test_successful_refund_with_google_pay
    auth = @tandem_gateway.authorize(@amount, @google_pay_card, @options)
    assert_success auth
    assert_equal 'Approved', auth.message

    capture = @tandem_gateway.capture(@amount, auth.authorization, @options)
    assert_success capture

    assert capture.authorization
    assert refund = @tandem_gateway.refund(@amount, capture.authorization, @options)
    assert_success refund
  end

  def test_successful_refund_with_level_2_data
    amount = @amount
    assert response = @tandem_gateway.purchase(amount, @credit_card, @options.merge(level_2_data: @level_2_options))
    assert_success response
    assert response.authorization
    assert refund = @tandem_gateway.refund(amount, response.authorization, @options.merge(level_2_data: @level_2_options))
    assert_success refund
  end

  def test_successful_credit
    payment_method = credit_card('5454545454545454')
    assert response = @tandem_gateway.credit(@amount, payment_method, @options)
    assert_success response
  end

  def test_failed_capture
    assert response = @tandem_gateway.capture(@amount, '')
    assert_failure response
    assert_equal 'Bad data error', response.message
  end

  def test_credit_purchase_with_address_responds_with_name
    transcript = capture_transcript(@tandem_gateway) do
      response = @tandem_gateway.authorize(@amount, @credit_card, @options.merge(order_id: '2'))
      assert_equal '00', response.params['resp_code']
      assert_equal 'Approved', response.params['status_msg']
    end

    assert_match(/<AVSname>Longbob Longsen/, transcript)
  end

  def test_credit_purchase_with_no_address_responds_with_no_name
    response = @tandem_gateway.authorize(@amount, @credit_card, @options.merge(order_id: '2', address: nil, billing_address: nil))
    assert_equal '00', response.params['resp_code']
    assert_equal 'Approved', response.params['status_msg']
  end

  def test_void_transactions
    [3000, 105500, 2900].each do |amount|
      assert auth_response = @tandem_gateway.authorize(amount, @credit_card, @options)
      assert void_response = @tandem_gateway.void(auth_response.authorization, @options.merge(transaction_index: 1))
      assert_kind_of Response, void_response
    end
  end

  def test_successful_verify
    response = @tandem_gateway.verify(@credit_card, @options)
    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_different_cards
    @credit_card.brand = 'master'
    response = @tandem_gateway.verify(@credit_card, @options)
    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_successful_verify_with_discover_brand
    @credit_card.brand = 'discover'
    response = @tandem_gateway.verify(@credit_card, @options)
    assert_success response
    assert_equal 'Approved', response.message
  end

  def test_unsuccessful_verify_with_invalid_discover_card
    @declined_card.brand = 'discover'
    response = @tandem_gateway.verify(@declined_card, @options.merge({ verify_amount: '101' }))
    assert_failure response
    assert_match 'AUTH DECLINED', response.message
  end

  def test_failed_verify
    response = @tandem_gateway.verify(@declined_card, @options.merge({ verify_amount: '101' }))
    assert_failure response
    assert_match 'AUTH DECLINED', response.message
  end

  def test_transcript_scrubbing
    transcript = capture_transcript(@tandem_gateway) do
      @tandem_gateway.purchase(@amount, @credit_card, @options)
    end
    transcript = @tandem_gateway.scrub(transcript)

    assert_scrubbed(@credit_card.number, transcript)
    assert_scrubbed(@credit_card.verification_value, transcript)
    assert_scrubbed(@tandem_gateway.options[:password], transcript)
    assert_scrubbed(@tandem_gateway.options[:login], transcript)
    assert_scrubbed(@tandem_gateway.options[:merchant_id], transcript)
  end

  def test_transcript_scrubbing_profile
    transcript = capture_transcript(@tandem_gateway) do
      @tandem_gateway.add_customer_profile(@credit_card, @options)
    end
    transcript = @tandem_gateway.scrub(transcript)

    assert_scrubbed(@credit_card.number, transcript)
    assert_scrubbed(@credit_card.verification_value, transcript)
    assert_scrubbed(@tandem_gateway.options[:password], transcript)
    assert_scrubbed(@tandem_gateway.options[:login], transcript)
    assert_scrubbed(@tandem_gateway.options[:merchant_id], transcript)
  end

  def test_transcript_scrubbing_network_card
    network_card = network_tokenization_credit_card(
      '4788250000028291',
      payment_cryptogram: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      transaction_id: 'BwABB4JRdgAAAAAAiFF2AAAAAAA=',
      verification_value: '111',
      brand: 'visa',
      eci: '5'
    )
    transcript = capture_transcript(@tandem_gateway) do
      @tandem_gateway.purchase(@tandem_gateway, network_card, @options)
    end
    transcript = @tandem_gateway.scrub(transcript)

    assert_scrubbed(network_card.payment_cryptogram, transcript)
  end

  private

  def stored_credential_options(*args, id: nil)
    @options.merge(order_id: generate_unique_id,
                   stored_credential: stored_credential(*args, id:))
  end
end
