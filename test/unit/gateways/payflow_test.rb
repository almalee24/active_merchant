require 'test_helper'

class PayflowTest < Test::Unit::TestCase
  include CommStub

  # From `BuyerAuthStatusEnum` in https://www.paypalobjects.com/webstatic/en_US/developer/docs/pdf/pp_payflowpro_xmlpay_guide.pdf, page 109
  SUCCESSFUL_AUTHENTICATION_STATUS = 'Y'
  CHALLENGE_REQUIRED_AUTHENTICATION_STATUS = 'C'

  def setup
    Base.mode = :test

    @gateway = PayflowGateway.new(
      login: 'LOGIN',
      password: 'PASSWORD'
    )

    @amount = 100
    @credit_card = credit_card('4242424242424242')
    @options = { billing_address: address.merge(first_name: 'Longbob', last_name: 'Longsen') }
    @check = check(name: 'Jim Smith')
    @l2_json = '{
      "Tender": {
        "ACH": {
          "AcctType": "C",
          "AcctNum": "6355059797",
          "ABA": "021000021"
        }
      }
    }'

    @l3_json = '{
      "Invoice": {
        "Date": "20190104",
        "Level3Invoice": {
          "CountyTax": {"Amount": "3.23"}
        }
      }
    }'
  end

  def test_successful_authorization
    @gateway.stubs(:ssl_post).returns(successful_authorization_response)

    assert response = @gateway.authorize(@amount, @credit_card, @options)
    assert_equal 'Approved', response.message
    assert_success response
    assert response.test?
    assert_equal 'VUJN1A6E11D9', response.authorization
    refute response.fraud_review?
  end

  def test_successful_purchase_with_stored_credential
    @options[:stored_credential] = {
      initial_transaction: false,
      reason_type: 'recurring',
      initiator: 'cardholder',
      network_transaction_id: nil
    }
    stub_comms do
      @gateway.purchase(@amount, @credit_card, @options)
    end.check_request do |_endpoint, data, _headers|
      assert_match %r(<CardOnFile>CITR</CardOnFile>), data
    end.respond_with(successful_purchase_with_fraud_review_response)

    @options[:stored_credential] = {
      initial_transaction: true,
      reason_type: 'unscheduled',
      initiator: 'cardholder',
      network_transaction_id: nil
    }
    stub_comms do
      @gateway.purchase(@amount, @credit_card, @options)
    end.check_request do |_endpoint, data, _headers|
      assert_match %r(<CardOnFile>CITI</CardOnFile>), data
    end.respond_with(successful_purchase_with_fraud_review_response)

    @options[:stored_credential] = {
      initial_transaction: false,
      reason_type: 'unscheduled',
      initiator: 'cardholder',
      network_transaction_id: nil
    }
    stub_comms do
      @gateway.purchase(@amount, @credit_card, @options)
    end.check_request do |_endpoint, data, _headers|
      assert_match %r(<CardOnFile>CITU</CardOnFile>), data
    end.respond_with(successful_purchase_with_fraud_review_response)

    @options[:stored_credential] = {
      initial_transaction: false,
      reason_type: 'recurring',
      initiator: 'merchant',
      network_transaction_id: '1234'
    }
    stub_comms do
      @gateway.purchase(@amount, @credit_card, @options)
    end.check_request do |_endpoint, data, _headers|
      assert_match %r(<CardOnFile>MITR</CardOnFile>), data
      assert_match %r(<TxnId>1234</TxnId>), data
    end.respond_with(successful_purchase_with_fraud_review_response)

    @options[:stored_credential] = {
      initial_transaction: false,
      reason_type: 'unscheduled',
      initiator: 'merchant',
      network_transaction_id: '123'
    }
    stub_comms do
      @gateway.purchase(@amount, @credit_card, @options)
    end.check_request do |_endpoint, data, _headers|
      assert_match %r(<CardOnFile>MITU</CardOnFile>), data
      assert_match %r(<TxnId>123</TxnId>), data
    end.respond_with(successful_purchase_with_fraud_review_response)
  end

  def test_failed_authorization
    @gateway.stubs(:ssl_post).returns(failed_authorization_response)

    assert response = @gateway.authorize(@amount, @credit_card, @options)
    assert_equal 'Declined', response.message
    assert_failure response
    assert response.test?
  end

  def test_authorization_with_three_d_secure_option
    response = stub_comms do
      @gateway.authorize(@amount, @credit_card, @options.merge(three_d_secure_option))
    end.check_request do |_endpoint, data, _headers|
      assert_three_d_secure REXML::Document.new(data), authorize_buyer_auth_result_path
    end.respond_with(successful_authorization_response)
    assert_equal 'Approved', response.message
    assert_success response
    assert response.test?
    assert_equal 'VUJN1A6E11D9', response.authorization
    refute response.fraud_review?
  end

  def test_authorization_with_three_d_secure_option_with_version_includes_three_ds_version
    expected_version = '1.0.2'
    three_d_secure_option = three_d_secure_option(options: { version: expected_version })
    stub_comms do
      @gateway.authorize(@amount, @credit_card, @options.merge(three_d_secure_option))
    end.check_request do |_endpoint, data, _headers|
      assert_three_d_secure REXML::Document.new(data), authorize_buyer_auth_result_path, expected_version:
    end.respond_with(successful_authorization_response)
  end

  def test_authorization_with_three_d_secure_option_with_ds_transaction_id_includes_ds_transaction_id
    expected_ds_transaction_id = 'any ds_transaction id'
    three_d_secure_option = three_d_secure_option(options: { ds_transaction_id: expected_ds_transaction_id })
    stub_comms do
      @gateway.authorize(@amount, @credit_card, @options.merge(three_d_secure_option))
    end.check_request do |_endpoint, data, _headers|
      assert_three_d_secure REXML::Document.new(data), authorize_buyer_auth_result_path, expected_ds_transaction_id:
    end.respond_with(successful_authorization_response)
  end

  def test_authorization_with_three_d_secure_option_with_version_2_x_via_mpi
    expected_version = '2.2.0'
    expected_authentication_status = SUCCESSFUL_AUTHENTICATION_STATUS
    expected_ds_transaction_id = 'f38e6948-5388-41a6-bca4-b49723c19437'

    three_d_secure_option = three_d_secure_option(options: { version: expected_version, ds_transaction_id: expected_ds_transaction_id })
    stub_comms do
      @gateway.authorize(@amount, @credit_card, @options.merge(three_d_secure_option))
    end.check_request do |_endpoint, data, _headers|
      xml = REXML::Document.new(data)
      assert_three_d_secure_via_mpi(xml, tx_type: 'Authorization', expected_version:, expected_ds_transaction_id:)
      assert_three_d_secure xml, authorize_buyer_auth_result_path, expected_version:, expected_authentication_status:, expected_ds_transaction_id:
    end.respond_with(successful_authorization_response)
  end

  def test_authorization_with_three_d_secure_option_with_version_2_x_and_authentication_response_status_include_authentication_status
    expected_version = '2.2.0'
    expected_authentication_status = SUCCESSFUL_AUTHENTICATION_STATUS
    three_d_secure_option = three_d_secure_option(options: { version: expected_version })
    stub_comms do
      @gateway.authorize(@amount, @credit_card, @options.merge(three_d_secure_option))
    end.check_request do |_endpoint, data, _headers|
      assert_three_d_secure REXML::Document.new(data), authorize_buyer_auth_result_path, expected_version:, expected_authentication_status:
    end.respond_with(successful_authorization_response)
  end

  def test_authorization_with_three_d_secure_option_with_version_1_x_and_authentication_response_status_does_not_include_authentication_status
    expected_version = '1.0.2'
    expected_authentication_status = nil
    three_d_secure_option = three_d_secure_option(options: { version: expected_version })
    stub_comms do
      @gateway.authorize(@amount, @credit_card, @options.merge(three_d_secure_option))
    end.check_request do |_endpoint, data, _headers|
      assert_three_d_secure REXML::Document.new(data), authorize_buyer_auth_result_path, expected_version:, expected_authentication_status:
    end.respond_with(successful_authorization_response)
  end

  def test_successful_authorization_with_more_options
    partner_id = 'partner_id'
    PayflowGateway.application_id = partner_id

    options = @options.merge(
      {
        order_id: '123',
        description: 'Description string',
        order_desc: 'OrderDesc string',
        comment: 'Comment string',
        comment2: 'Comment2 string',
        merch_descr: 'MerchDescr string'
      }
    )

    response = stub_comms do
      @gateway.authorize(@amount, @credit_card, options)
    end.check_request do |_endpoint, data, _headers|
      assert_match %r(<InvNum>123</InvNum>), data
      assert_match %r(<Description>Description string</Description>), data
      assert_match %r(<OrderDesc>OrderDesc string</OrderDesc>), data
      assert_match %r(<Comment>Comment string</Comment>), data
      assert_match %r(<ExtData Name=\"COMMENT2\" Value=\"Comment2 string\"/>), data
      assert_match %r(</PayData><ExtData Name=\"BUTTONSOURCE\" Value=\"partner_id\"/></Authorization>), data
      assert_match %r(<MerchDescr>MerchDescr string</MerchDescr>), data
    end.respond_with(successful_authorization_response)
    assert_equal 'Approved', response.message
    assert_success response
    assert response.test?
    assert_equal 'VUJN1A6E11D9', response.authorization
    refute response.fraud_review?
  end

  def test_successful_purchase_with_fraud_review
    @gateway.stubs(:ssl_post).returns(successful_purchase_with_fraud_review_response)

    assert response = @gateway.purchase(@amount, @credit_card, @options)
    assert_success response
    assert_equal '126', response.params['result']
    assert response.fraud_review?
  end

  def test_successful_purchase_with_three_d_secure_option
    response = stub_comms do
      @gateway.purchase(@amount, @credit_card, @options.merge(three_d_secure_option))
    end.check_request do |_endpoint, data, _headers|
      assert_three_d_secure REXML::Document.new(data), purchase_buyer_auth_result_path
    end.respond_with(successful_purchase_with_fraud_review_response)
    assert_success response
    assert_equal '126', response.params['result']
    assert response.fraud_review?
  end

  def test_successful_purchase_with_three_d_secure_option_with_version_2_x_via_mpi
    expected_version = '2.2.0'
    expected_authentication_status = SUCCESSFUL_AUTHENTICATION_STATUS
    expected_ds_transaction_id = 'f38e6948-5388-41a6-bca4-b49723c19437'

    three_d_secure_option = three_d_secure_option(options: { version: expected_version, ds_transaction_id: expected_ds_transaction_id })
    response = stub_comms do
      @gateway.purchase(@amount, @credit_card, @options.merge(three_d_secure_option))
    end.check_request do |_endpoint, data, _headers|
      xml = REXML::Document.new(data)
      assert_three_d_secure_via_mpi xml, tx_type: 'Sale', expected_version: expected_version, expected_ds_transaction_id: expected_ds_transaction_id

      assert_three_d_secure xml, purchase_buyer_auth_result_path, expected_version: expected_version, expected_authentication_status: expected_authentication_status, expected_ds_transaction_id: expected_ds_transaction_id
    end.respond_with(successful_purchase_with_3ds_mpi)
    assert_success response

    # see https://www.paypalobjects.com/webstatic/en_US/developer/docs/pdf/pp_payflowpro_xmlpay_guide.pdf, page 145, Table C.1
    assert_equal '0', response.params['result']
    refute response.fraud_review?
  end

  def test_successful_purchase_with_level_2_fields
    options = @options.merge(level_two_fields: @l2_json)

    response = stub_comms do
      @gateway.purchase(@amount, @credit_card, options)
    end.check_request do |_endpoint, data, _headers|
      assert_match %r(<AcctNum>6355059797</AcctNum>), data
      assert_match %r(<ACH><AcctType>), data.tr("\n ", '')
    end.respond_with(successful_l2_response)
    assert_equal 'Approved', response.message
    assert_success response
    assert_equal 'A1ADADCE9B12', response.authorization
    refute response.fraud_review?
  end

  def test_successful_purchase_with_level_3_fields
    options = @options.merge(level_three_fields: @l3_json)

    response = stub_comms do
      @gateway.purchase(@amount, @credit_card, options)
    end.check_request do |_endpoint, data, _headers|
      assert_match %r(<Date>20190104</Date>), data
      assert_match %r(<Amount>3.23</Amount>), data
      assert_match %r(<Level3Invoice><CountyTax><Amount>), data.tr("\n ", '')
    end.respond_with(successful_l3_response)
    assert_equal 'Approved', response.message
    assert_success response
    assert_equal 'A71AAC3B60A1', response.authorization
    refute response.fraud_review?
  end

  def test_successful_purchase_with_level_2_3_fields
    options = @options.merge(level_two_fields: @l2_json).merge(level_three_fields: @l3_json)

    response = stub_comms do
      @gateway.purchase(@amount, @credit_card, options)
    end.check_request do |_endpoint, data, _headers|
      assert_match %r(<Date>20190104</Date>), data
      assert_match %r(<Amount>3.23</Amount>), data
      assert_match %r(<AcctNum>6355059797</AcctNum>), data
      assert_match %r(<ACH><AcctType>), data.tr("\n ", '')
      assert_match %r(<Level3Invoice><CountyTax><Amount>), data.tr("\n ", '')
    end.respond_with(successful_l2_response)
    assert_equal 'Approved', response.message
    assert_success response
    assert_equal 'A1ADADCE9B12', response.authorization
    refute response.fraud_review?
  end

  def test_credit
    @gateway.expects(:ssl_post).with(anything, regexp_matches(/<CardNum>#{@credit_card.number}<\//), anything).returns('')
    @gateway.expects(:parse).returns({})
    @gateway.credit(@amount, @credit_card, @options)
  end

  def test_deprecated_credit
    @gateway.expects(:ssl_post).with(anything, regexp_matches(/<PNRef>transaction_id<\//), anything).returns('')
    @gateway.expects(:parse).returns({})
    assert_deprecation_warning(Gateway::CREDIT_DEPRECATION_MESSAGE) do
      @gateway.credit(@amount, 'transaction_id', @options)
    end
  end

  def test_refund
    @gateway.expects(:ssl_post).with(anything, regexp_matches(/<PNRef>transaction_id<\//), anything).returns('')
    @gateway.expects(:parse).returns({})
    @gateway.refund(@amount, 'transaction_id', @options)
  end

  def test_avs_result
    @gateway.expects(:ssl_post).returns(successful_authorization_response)

    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_equal 'Y', response.avs_result['code']
    assert_equal 'Y', response.avs_result['street_match']
    assert_equal 'Y', response.avs_result['postal_match']
  end

  def test_partial_avs_match
    @gateway.expects(:ssl_post).returns(successful_duplicate_response)

    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_equal 'A', response.avs_result['code']
    assert_equal 'Y', response.avs_result['street_match']
    assert_equal 'N', response.avs_result['postal_match']
  end

  def test_cvv_result
    @gateway.expects(:ssl_post).returns(successful_authorization_response)

    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_equal 'M', response.cvv_result['code']
  end

  def test_ach_purchase
    @gateway.expects(:ssl_post).with(anything, regexp_matches(/<AcctNum>#{@check.account_number}<\//), anything).returns('')
    @gateway.expects(:parse).returns({})
    @gateway.purchase(@amount, @check)
  end

  def test_ach_credit
    @gateway.expects(:ssl_post).with(anything, regexp_matches(/<AcctNum>#{@check.account_number}<\//), anything).returns('')
    @gateway.expects(:parse).returns({})
    @gateway.credit(@amount, @check)
  end

  def test_using_test_mode
    assert @gateway.test?
  end

  def test_overriding_test_mode
    Base.mode = :production

    gateway = PayflowGateway.new(
      login: 'LOGIN',
      password: 'PASSWORD',
      test: true
    )

    assert gateway.test?
  end

  def test_using_production_mode
    Base.mode = :production

    gateway = PayflowGateway.new(
      login: 'LOGIN',
      password: 'PASSWORD'
    )

    refute gateway.test?
  end

  def test_partner_class_accessor
    assert_equal 'PayPal', PayflowGateway.partner
    gateway = PayflowGateway.new(login: 'test', password: 'test')
    assert_equal 'PayPal', gateway.options[:partner]
  end

  def test_partner_class_accessor_used_when_passed_in_partner_is_blank
    assert_equal 'PayPal', PayflowGateway.partner
    gateway = PayflowGateway.new(login: 'test', password: 'test', partner: '')
    assert_equal 'PayPal', gateway.options[:partner]
  end

  def test_passed_in_partner_overrides_class_accessor
    assert_equal 'PayPal', PayflowGateway.partner
    gateway = PayflowGateway.new(login: 'test', password: 'test', partner: 'PayPalUk')
    assert_equal 'PayPalUk', gateway.options[:partner]
  end

  def test_express_instance
    gateway = PayflowGateway.new(
      login: 'test',
      password: 'password'
    )
    express = gateway.express
    assert_instance_of PayflowExpressGateway, express
    assert_equal 'PayPal', express.options[:partner]
    assert_equal 'test', express.options[:login]
    assert_equal 'password', express.options[:password]
  end

  def test_default_currency
    assert_equal 'USD', PayflowGateway.default_currency
  end

  def test_supported_countries
    assert_equal %w[US CA NZ AU], PayflowGateway.supported_countries
  end

  def test_supported_card_types
    assert_equal %i[visa master american_express jcb discover diners_club], PayflowGateway.supported_cardtypes
  end

  def test_successful_verify
    response = stub_comms(@gateway) do
      @gateway.verify(@credit_card, @options)
    end.respond_with(successful_authorization_response)
    assert_success response
  end

  def test_unsuccessful_verify
    response = stub_comms(@gateway) do
      @gateway.verify(@credit_card, @options)
    end.respond_with(failed_authorization_response)
    assert_failure response
    assert_equal 'Declined', response.message
  end

  def test_store_returns_error
    error = assert_raises(ArgumentError) { @gateway.store(@credit_card, @options) }
    assert_equal 'Store is not supported on Payflow gateways', error.message
  end

  def test_initial_recurring_transaction_missing_parameters
    assert_raises ArgumentError do
      assert_deprecation_warning(Gateway::RECURRING_DEPRECATION_MESSAGE) do
        @gateway.recurring(
          @amount,
          @credit_card,
          periodicity: :monthly,
          initial_transaction: {}
        )
      end
    end
  end

  def test_initial_purchase_missing_amount
    assert_raises ArgumentError do
      assert_deprecation_warning(Gateway::RECURRING_DEPRECATION_MESSAGE) do
        @gateway.recurring(
          @amount,
          @credit_card,
          periodicity: :monthly,
          initial_transaction: { amount: :purchase }
        )
      end
    end
  end

  def test_recurring_add_action_missing_parameters
    assert_raises ArgumentError do
      assert_deprecation_warning(Gateway::RECURRING_DEPRECATION_MESSAGE) do
        @gateway.recurring(@amount, @credit_card)
      end
    end
  end

  def test_recurring_modify_action_missing_parameters
    assert_raises ArgumentError do
      assert_deprecation_warning(Gateway::RECURRING_DEPRECATION_MESSAGE) do
        @gateway.recurring(@amount, nil)
      end
    end
  end

  def test_successful_recurring_action
    @gateway.stubs(:ssl_post).returns(successful_recurring_response)

    response = assert_deprecation_warning(Gateway::RECURRING_DEPRECATION_MESSAGE) do
      @gateway.recurring(@amount, @credit_card, periodicity: :monthly)
    end

    assert_instance_of PayflowResponse, response
    assert_success response
    assert_equal 'RT0000000009', response.profile_id
    assert response.test?
    assert_equal 'R7960E739F80', response.authorization
  end

  def test_successful_recurring_modify_action
    @gateway.stubs(:ssl_post).returns(successful_recurring_response)

    response = assert_deprecation_warning(Gateway::RECURRING_DEPRECATION_MESSAGE) do
      @gateway.recurring(@amount, nil, profile_id: 'RT0000000009', periodicity: :monthly)
    end

    assert_instance_of PayflowResponse, response
    assert_success response
    assert_equal 'RT0000000009', response.profile_id
    assert response.test?
    assert_equal 'R7960E739F80', response.authorization
  end

  def test_successful_recurring_modify_action_with_retry_num_days
    @gateway.stubs(:ssl_post).returns(successful_recurring_response)

    response = assert_deprecation_warning(Gateway::RECURRING_DEPRECATION_MESSAGE) do
      @gateway.recurring(@amount, nil, profile_id: 'RT0000000009', retry_num_days: 3, periodicity: :monthly)
    end

    assert_instance_of PayflowResponse, response
    assert_success response
    assert_equal 'RT0000000009', response.profile_id
    assert response.test?
    assert_equal 'R7960E739F80', response.authorization
  end

  def test_falied_recurring_modify_action_with_starting_at_in_the_past
    @gateway.stubs(:ssl_post).returns(start_date_error_recurring_response)

    response = assert_deprecation_warning(Gateway::RECURRING_DEPRECATION_MESSAGE) do
      @gateway.recurring(@amount, nil, profile_id: 'RT0000000009', starting_at: Date.yesterday, periodicity: :monthly)
    end

    assert_instance_of PayflowResponse, response
    assert_success response
    assert_equal 'RT0000000009', response.profile_id
    assert_equal 'Field format error: START or NEXTPAYMENTDATE older than last payment date', response.message
    assert response.test?
    assert_equal 'R7960E739F80', response.authorization
  end

  def test_falied_recurring_modify_action_with_starting_at_missing_and_changed_periodicity
    @gateway.stubs(:ssl_post).returns(start_date_missing_recurring_response)

    response = assert_deprecation_warning(Gateway::RECURRING_DEPRECATION_MESSAGE) do
      @gateway.recurring(@amount, nil, profile_id: 'RT0000000009', periodicity: :yearly)
    end

    assert_instance_of PayflowResponse, response
    assert_success response
    assert_equal 'RT0000000009', response.profile_id
    assert_equal 'Field format error: START field missing', response.message
    assert response.test?
    assert_equal 'R7960E739F80', response.authorization
  end

  def test_recurring_profile_payment_history_inquiry
    @gateway.stubs(:ssl_post).returns(successful_payment_history_recurring_response)

    response = assert_deprecation_warning(Gateway::RECURRING_DEPRECATION_MESSAGE) do
      @gateway.recurring_inquiry('RT0000000009', history: true)
    end
    assert_equal 1, response.payment_history.size
    assert_equal '1', response.payment_history.first['payment_num']
    assert_equal '7.25', response.payment_history.first['amt']
  end

  def test_recurring_profile_payment_history_inquiry_contains_the_proper_xml
    request = @gateway.send(:build_recurring_request, :inquiry, nil, profile_id: 'RT0000000009', history: true)
    assert_match %r(<PaymentHistory>Y</PaymentHistory), request
  end

  def test_add_credit_card_with_three_d_secure
    xml = Builder::XmlMarkup.new
    credit_card = credit_card(
      '5641820000000005',
      brand: 'maestro'
    )

    @gateway.send(:add_credit_card, xml, credit_card, @options.merge(three_d_secure_option))
    assert_three_d_secure REXML::Document.new(xml.target!), '/Card/BuyerAuthResult'
  end

  def test_add_credit_card_with_three_d_secure_challenge_required
    xml = Builder::XmlMarkup.new
    credit_card = credit_card(
      '5641820000000005',
      brand: 'maestro'
    )

    three_d_secure_option = three_d_secure_option(
      options: {
        authentication_response_status: nil,
        directory_response_status: CHALLENGE_REQUIRED_AUTHENTICATION_STATUS
      }
    )
    @gateway.send(:add_credit_card, xml, credit_card, @options.merge(three_d_secure_option))
    assert_three_d_secure(
      REXML::Document.new(xml.target!),
      '/Card/BuyerAuthResult',
      expected_status: CHALLENGE_REQUIRED_AUTHENTICATION_STATUS
    )
  end

  def test_duplicate_response_flag
    @gateway.expects(:ssl_post).returns(successful_duplicate_response)

    response = @gateway.authorize(@amount, @credit_card, @options)
    assert_success response
    assert response.params['duplicate']
  end

  def test_ensure_gateway_uses_safe_retry
    assert @gateway.retry_safe
  end

  def test_timeout_is_same_in_header_and_xml
    timeout = PayflowGateway.timeout.to_s

    headers = @gateway.send(:build_headers, 1)
    assert_equal timeout, headers['X-VPS-Client-Timeout']

    xml = @gateway.send(:build_request, 'dummy body')
    assert_match %r{Timeout="#{timeout}"}, xml
  end

  def test_name_field_are_included_instead_of_first_and_last
    @gateway.expects(:ssl_post).returns(successful_authorization_response).with do |_url, data|
      data !~ /FirstName/ && data !~ /LastName/ && data =~ /<Name>/
    end
    response = @gateway.authorize(@amount, @credit_card, @options)
    assert_success response
  end

  def test_passed_in_verbosity
    assert_nil PayflowGateway.new(login: 'test', password: 'test').options[:verbosity]
    gateway = PayflowGateway.new(login: 'test', password: 'test', verbosity: 'HIGH')
    assert_equal 'HIGH', gateway.options[:verbosity]
    @gateway.expects(:ssl_post).returns(verbose_transaction_response)
    response = @gateway.purchase(100, @credit_card, @options)
    assert_success response
    assert_equal '2014-06-25 09:33:41', response.params['transaction_time']
  end

  def test_paypal_nvp_option_sends_header
    headers = @gateway.send(:build_headers, 1)
    assert_not_include headers, 'PAYPAL-NVP'

    old_use_paypal_nvp = PayflowGateway.use_paypal_nvp
    PayflowGateway.use_paypal_nvp = true
    headers = @gateway.send(:build_headers, 1)
    assert_equal 'Y', headers['PAYPAL-NVP']
    PayflowGateway.use_paypal_nvp = old_use_paypal_nvp
  end

  def test_scrub
    assert @gateway.supports_scrubbing?
    assert_equal @gateway.scrub(pre_scrubbed), post_scrubbed
    assert_equal @gateway.scrub(pre_scrubbed_check), post_scrubbed_check
  end

  def test_adds_cavv_as_xid_if_xid_is_not_present
    cavv = 'jGvQIvG/5UhjAREALGYa6Vu/hto='
    threeds_options = @options.merge(
      three_d_secure: {
        version: '2.0',
        cavv:
      }
    )

    stub_comms do
      @gateway.purchase(@amount, @credit_card, @options.merge(threeds_options))
    end.check_request do |_endpoint, data, _headers|
      assert_match %r(<ExtData Name=\"XID\" Value=\"#{cavv}\"/>), data
      assert_match %r(<XID>#{cavv}</XID>), data
    end.respond_with(successful_purchase_with_3ds_mpi)
  end

  def test_does_not_add_cavv_as_xid_if_xid_is_present
    threeds_options = @options.merge(
      three_d_secure: {
        version: '2.0',
        xid: 'this-is-an-xid',
        cavv: 'jGvQIvG/5UhjAREALGYa6Vu/hto='
      }
    )

    stub_comms do
      @gateway.purchase(@amount, @credit_card, @options.merge(threeds_options))
    end.check_request do |_endpoint, data, _headers|
      assert_match %r(<ExtData Name="XID" Value="this-is-an-xid"/>), data
      assert_match %r(<XID>this-is-an-xid</XID>), data
    end.respond_with(successful_purchase_with_3ds_mpi)
  end

  private

  def pre_scrubbed
    <<~REQUEST
      opening connection to pilot-payflowpro.paypal.com:443...
      opened
      starting SSL for pilot-payflowpro.paypal.com:443...
      SSL established
      <- "POST / HTTP/1.1\r\nContent-Type: text/xml\r\nContent-Length: 1017\r\nX-Vps-Client-Timeout: 60\r\nX-Vps-Vit-Integration-Product: ActiveMerchant\r\nX-Vps-Vit-Runtime-Version: 2.1.7\r\nX-Vps-Request-Id: 3b2f9831949b48b4b0b89a33a60f9b0c\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: pilot-payflowpro.paypal.com\r\n\r\n"
      <- "<?xml version=\"1.0\" encoding=\"UTF-8\"?><XMLPayRequest Timeout=\"60\" version=\"2.1\" xmlns=\"http://www.paypal.com/XMLPay\"><RequestData><Vendor>spreedlyIntegrations</Vendor><Partner>PayPal</Partner><Transactions><Transaction CustRef=\"codyexample\"><Verbosity>MEDIUM</Verbosity><Sale><PayData><Invoice><EMail>cody@example.com</EMail><BillTo><Name>Jim Smith</Name><EMail>cody@example.com</EMail><Phone>(555)555-5555</Phone><CustCode>codyexample</CustCode><Address><Street>456 My Street</Street><City>Ottawa</City><State>ON</State><Country>CA</Country><Zip>K1C2N6</Zip></Address></BillTo><TotalAmt Currency=\"USD\"/></Invoice><Tender><Card><CardType>MasterCard</CardType><CardNum>5105105105105100</CardNum><ExpDate>201909</ExpDate><NameOnCard>Longbob</NameOnCard><CVNum>123</CVNum><ExtData Name=\"LASTNAME\" Value=\"Longsen\"/></Card></Tender></PayData></Sale></Transaction></Transactions></RequestData><RequestAuth><UserPass><User>spreedlyIntegrations</User><Password>L9DjqEKjXCkU</Password></UserPass></RequestAuth></XMLPayRequest>"
      -> "HTTP/1.1 200 OK\r\n"
      -> "Connection: close\r\n"
      -> "Server: VPS-3.033.00\r\n"
      -> "X-VPS-Request-ID: 3b2f9831949b48b4b0b89a33a60f9b0c\r\n"
      -> "Date: Thu, 01 Mar 2018 15:42:15 GMT\r\n"
      -> "Content-type: text/xml\r\n"
      -> "Content-length:    267\r\n"
      -> "\r\n"
      reading 267 bytes...
      -> "<XMLPayResponse  xmlns=\"http://www.paypal.com/XMLPay\"><ResponseData><Vendor></Vendor><Partner></Partner><TransactionResults><TransactionResult><Result>4</Result><Message>Invalid amount</Message></TransactionResult></TransactionResults></ResponseData></XMLPayResponse>"
      read 267 bytes
      Conn close
    REQUEST
  end

  def post_scrubbed
    <<~REQUEST
      opening connection to pilot-payflowpro.paypal.com:443...
      opened
      starting SSL for pilot-payflowpro.paypal.com:443...
      SSL established
      <- "POST / HTTP/1.1\r\nContent-Type: text/xml\r\nContent-Length: 1017\r\nX-Vps-Client-Timeout: 60\r\nX-Vps-Vit-Integration-Product: ActiveMerchant\r\nX-Vps-Vit-Runtime-Version: 2.1.7\r\nX-Vps-Request-Id: 3b2f9831949b48b4b0b89a33a60f9b0c\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: pilot-payflowpro.paypal.com\r\n\r\n"
      <- "<?xml version=\"1.0\" encoding=\"UTF-8\"?><XMLPayRequest Timeout=\"60\" version=\"2.1\" xmlns=\"http://www.paypal.com/XMLPay\"><RequestData><Vendor>spreedlyIntegrations</Vendor><Partner>PayPal</Partner><Transactions><Transaction CustRef=\"codyexample\"><Verbosity>MEDIUM</Verbosity><Sale><PayData><Invoice><EMail>cody@example.com</EMail><BillTo><Name>Jim Smith</Name><EMail>cody@example.com</EMail><Phone>(555)555-5555</Phone><CustCode>codyexample</CustCode><Address><Street>456 My Street</Street><City>Ottawa</City><State>ON</State><Country>CA</Country><Zip>K1C2N6</Zip></Address></BillTo><TotalAmt Currency=\"USD\"/></Invoice><Tender><Card><CardType>MasterCard</CardType><CardNum>[FILTERED]</CardNum><ExpDate>201909</ExpDate><NameOnCard>Longbob</NameOnCard><CVNum>[FILTERED]</CVNum><ExtData Name=\"LASTNAME\" Value=\"Longsen\"/></Card></Tender></PayData></Sale></Transaction></Transactions></RequestData><RequestAuth><UserPass><User>spreedlyIntegrations</User><Password>[FILTERED]</Password></UserPass></RequestAuth></XMLPayRequest>"
      -> "HTTP/1.1 200 OK\r\n"
      -> "Connection: close\r\n"
      -> "Server: VPS-3.033.00\r\n"
      -> "X-VPS-Request-ID: 3b2f9831949b48b4b0b89a33a60f9b0c\r\n"
      -> "Date: Thu, 01 Mar 2018 15:42:15 GMT\r\n"
      -> "Content-type: text/xml\r\n"
      -> "Content-length:    267\r\n"
      -> "\r\n"
      reading 267 bytes...
      -> "<XMLPayResponse  xmlns=\"http://www.paypal.com/XMLPay\"><ResponseData><Vendor></Vendor><Partner></Partner><TransactionResults><TransactionResult><Result>4</Result><Message>Invalid amount</Message></TransactionResult></TransactionResults></ResponseData></XMLPayResponse>"
      read 267 bytes
      Conn close
    REQUEST
  end

  def pre_scrubbed_check
    <<~REQUEST
      opening connection to pilot-payflowpro.paypal.com:443...
      opened
      starting SSL for pilot-payflowpro.paypal.com:443...
      SSL established
      <- "POST / HTTP/1.1\r\nContent-Type: text/xml\r\nContent-Length: 658\r\nX-Vps-Client-Timeout: 60\r\nX-Vps-Vit-Integration-Product: ActiveMerchant\r\nX-Vps-Vit-Runtime-Version: 2.1.7\r\nX-Vps-Request-Id: 863021e6890a0660238ef22d0a21c5f2\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: pilot-payflowpro.paypal.com\r\n\r\n"
      <- "<?xml version=\"1.0\" encoding=\"UTF-8\"?><XMLPayRequest Timeout=\"60\" version=\"2.1\" xmlns=\"http://www.paypal.com/XMLPay\"><RequestData><Vendor>spreedlyIntegrations</Vendor><Partner>PayPal</Partner><Transactions><Transaction CustRef=\"codyexample\"><Verbosity>MEDIUM</Verbosity><Sale><PayData><Invoice><BillTo><Name>Jim Smith</Name></BillTo><TotalAmt Currency=\"USD\"/></Invoice><Tender><ACH><AcctType>C</AcctType><AcctNum>1234567801</AcctNum><ABA>111111118</ABA></ACH></Tender></PayData></Sale></Transaction></Transactions></RequestData><RequestAuth><UserPass><User>spreedlyIntegrations</User><Password>L9DjqEKjXCkU</Password></UserPass></RequestAuth></XMLPayRequest>"
      -> "HTTP/1.1 200 OK\r\n"
      -> "Connection: close\r\n"
      -> "Server: VPS-3.033.00\r\n"
      -> "X-VPS-Request-ID: 863021e6890a0660238ef22d0a21c5f2\r\n"
      -> "Date: Thu, 01 Mar 2018 15:45:59 GMT\r\n"
      -> "Content-type: text/xml\r\n"
      -> "Content-length:    267\r\n"
      -> "\r\n"
      reading 267 bytes...
      -> "<XMLPayResponse  xmlns=\"http://www.paypal.com/XMLPay\"><ResponseData><Vendor></Vendor><Partner></Partner><TransactionResults><TransactionResult><Result>4</Result><Message>Invalid amount</Message></TransactionResult></TransactionResults></ResponseData></XMLPayResponse>"
      read 267 bytes
      Conn close
    REQUEST
  end

  def post_scrubbed_check
    <<~REQUEST
      opening connection to pilot-payflowpro.paypal.com:443...
      opened
      starting SSL for pilot-payflowpro.paypal.com:443...
      SSL established
      <- "POST / HTTP/1.1\r\nContent-Type: text/xml\r\nContent-Length: 658\r\nX-Vps-Client-Timeout: 60\r\nX-Vps-Vit-Integration-Product: ActiveMerchant\r\nX-Vps-Vit-Runtime-Version: 2.1.7\r\nX-Vps-Request-Id: 863021e6890a0660238ef22d0a21c5f2\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: pilot-payflowpro.paypal.com\r\n\r\n"
      <- "<?xml version=\"1.0\" encoding=\"UTF-8\"?><XMLPayRequest Timeout=\"60\" version=\"2.1\" xmlns=\"http://www.paypal.com/XMLPay\"><RequestData><Vendor>spreedlyIntegrations</Vendor><Partner>PayPal</Partner><Transactions><Transaction CustRef=\"codyexample\"><Verbosity>MEDIUM</Verbosity><Sale><PayData><Invoice><BillTo><Name>Jim Smith</Name></BillTo><TotalAmt Currency=\"USD\"/></Invoice><Tender><ACH><AcctType>C</AcctType><AcctNum>[FILTERED]</AcctNum><ABA>111111118</ABA></ACH></Tender></PayData></Sale></Transaction></Transactions></RequestData><RequestAuth><UserPass><User>spreedlyIntegrations</User><Password>[FILTERED]</Password></UserPass></RequestAuth></XMLPayRequest>"
      -> "HTTP/1.1 200 OK\r\n"
      -> "Connection: close\r\n"
      -> "Server: VPS-3.033.00\r\n"
      -> "X-VPS-Request-ID: 863021e6890a0660238ef22d0a21c5f2\r\n"
      -> "Date: Thu, 01 Mar 2018 15:45:59 GMT\r\n"
      -> "Content-type: text/xml\r\n"
      -> "Content-length:    267\r\n"
      -> "\r\n"
      reading 267 bytes...
      -> "<XMLPayResponse  xmlns=\"http://www.paypal.com/XMLPay\"><ResponseData><Vendor></Vendor><Partner></Partner><TransactionResults><TransactionResult><Result>4</Result><Message>Invalid amount</Message></TransactionResult></TransactionResults></ResponseData></XMLPayResponse>"
      read 267 bytes
      Conn close
    REQUEST
  end

  def successful_recurring_response
    <<~XML
      <ResponseData>
        <Result>0</Result>
        <Message>Approved</Message>
        <Partner>paypal</Partner>
        <RPRef>R7960E739F80</RPRef>
        <Vendor>ActiveMerchant</Vendor>
        <ProfileId>RT0000000009</ProfileId>
      </ResponseData>
    XML
  end

  def start_date_error_recurring_response
    <<~XML
      <ResponseData>
        <Result>0</Result>
        <Message>Field format error: START or NEXTPAYMENTDATE older than last payment date</Message>
        <Partner>paypal</Partner>
        <RPRef>R7960E739F80</RPRef>
        <Vendor>ActiveMerchant</Vendor>
        <ProfileId>RT0000000009</ProfileId>
      </ResponseData>
    XML
  end

  def start_date_missing_recurring_response
    <<~XML
      <ResponseData>
        <Result>0</Result>
        <Message>Field format error: START field missing</Message>
        <Partner>paypal</Partner>
        <RPRef>R7960E739F80</RPRef>
        <Vendor>ActiveMerchant</Vendor>
        <ProfileId>RT0000000009</ProfileId>
      </ResponseData>
    XML
  end

  def successful_payment_history_recurring_response
    <<~XML
      <ResponseData>
        <Result>0</Result>
        <Partner>paypal</Partner>
        <RPRef>R7960E739F80</RPRef>
        <Vendor>ActiveMerchant</Vendor>
        <ProfileId>RT0000000009</ProfileId>
        <RPPaymentResult>
          <PaymentNum>1</PaymentNum>
          <PNRef>V18A0D3048AF</PNRef>
          <TransTime>12-Jan-08 04:30 AM</TransTime>
          <Result>0</Result>
          <Tender>C</Tender>
          <Amt Currency="7.25"></Amt>
          <TransState>6</TransState>
        </RPPaymentResult>
      </ResponseData>
    XML
  end

  def successful_authorization_response
    <<~XML
      <ResponseData>
          <Result>0</Result>
          <Message>Approved</Message>
          <Partner>verisign</Partner>
          <HostCode>000</HostCode>
          <ResponseText>AP</ResponseText>
          <PnRef>VUJN1A6E11D9</PnRef>
          <IavsResult>N</IavsResult>
          <ZipMatch>Match</ZipMatch>
          <AuthCode>094016</AuthCode>
          <Vendor>ActiveMerchant</Vendor>
          <AvsResult>Y</AvsResult>
          <StreetMatch>Match</StreetMatch>
          <CvResult>Match</CvResult>
      </ResponseData>
    XML
  end

  def successful_purchase_with_3ds_mpi
    <<~XML
      <XMLPayResponse xmlns="http://www.paypal.com/XMLPay">
        <ResponseData>
          <Vendor>spreedlyIntegrations</Vendor>
          <Partner>paypal</Partner>
          <TransactionResults>
            <TransactionResult>
              <Result>0</Result>
              <ProcessorResult>
                <AVSResult>Z</AVSResult>
                <CVResult>M</CVResult>
                <HostCode>A</HostCode>
              </ProcessorResult>
              <FraudPreprocessResult>
                <Message>No Rules Triggered</Message>
              </FraudPreprocessResult>
              <FraudPostprocessResult>
                <Message>No Rules Triggered</Message>
              </FraudPostprocessResult>
              <IAVSResult>N</IAVSResult>
              <AVSResult>
                <StreetMatch>No Match</StreetMatch>
                <ZipMatch>Match</ZipMatch>
              </AVSResult>
              <CVResult>Match</CVResult>
              <Message>Approved</Message>
              <PNRef>A11AB1C8156A</PNRef>
              <AuthCode>980PNI</AuthCode>
            </TransactionResult>
          </TransactionResults>
        </ResponseData>
      </XMLPayResponse>
    XML
  end

  def successful_l3_response
    <<~XML
      <ResponseData>
        <Vendor>spreedlyIntegrations</Vendor>
        <Partner>paypal</Partner>
        <TransactionResults>
          <TransactionResult>
            <Result>0</Result>
            <ProcessorResult>
              <AVSResult>Z</AVSResult>
              <CVResult>M</CVResult>
              <HostCode>A</HostCode>
            </ProcessorResult>
            <FraudPreprocessResult>
              <Message>No Rules Triggered</Message>
            </FraudPreprocessResult>
            <FraudPostprocessResult>
              <Message>No Rules Triggered</Message>
            </FraudPostprocessResult>
            <IAVSResult>N</IAVSResult>
            <AVSResult>
              <StreetMatch>No Match</StreetMatch>
              <ZipMatch>Match</ZipMatch>
            </AVSResult>
            <CVResult>Match</CVResult>
            <Message>Approved</Message>
            <PNRef>A71AAC3B60A1</PNRef>
            <AuthCode>240PNI</AuthCode>
          </TransactionResult>
        </TransactionResults>
      </ResponseData>
    XML
  end

  def successful_l2_response
    <<~XML
      <ResponseData>
        <Vendor>spreedlyIntegrations</Vendor>
        <Partner>paypal</Partner>
        <TransactionResults>
          <TransactionResult>
            <Result>0</Result>
            <ProcessorResult>
              <HostCode>A</HostCode>
            </ProcessorResult>
            <Message>Approved</Message>
            <PNRef>A1ADADCE9B12</PNRef>
          </TransactionResult>
        </TransactionResults>
      </ResponseData>
    XML
  end

  def failed_authorization_response
    <<~XML
      <ResponseData>
          <Result>12</Result>
          <Message>Declined</Message>
          <Partner>verisign</Partner>
          <HostCode>000</HostCode>
          <ResponseText>AP</ResponseText>
          <PnRef>VUJN1A6E11D9</PnRef>
          <IavsResult>N</IavsResult>
          <ZipMatch>Match</ZipMatch>
          <AuthCode>094016</AuthCode>
          <Vendor>ActiveMerchant</Vendor>
          <AvsResult>Y</AvsResult>
          <StreetMatch>Match</StreetMatch>
          <CvResult>Match</CvResult>
      </ResponseData>
    XML
  end

  def successful_purchase_with_fraud_review_response
    <<~XML
      <XMLPayResponse  xmlns="http://www.paypal.com/XMLPay">
        <ResponseData>
          <Vendor>spreedly</Vendor>
          <Partner>paypal</Partner>
          <TransactionResults>
            <TransactionResult>
              <Result>126</Result>
              <ProcessorResult>
                <HostCode>A</HostCode>
              </ProcessorResult>
              <FraudPreprocessResult>
                <Message>Review HighRiskBinCheck</Message>
                <XMLData>
                  <triggeredRules>
                    <rule num="1">
                      <ruleId>13</ruleId>
                      <ruleID>13</ruleID>
                      <ruleAlias>HighRiskBinCheck</ruleAlias>
                      <ruleDescription>BIN Risk List Match</ruleDescription>
                      <action>R</action>
                      <triggeredMessage>The card number is in a high risk bin list</triggeredMessage>
                    </rule>
                  </triggeredRules>
                </XMLData>
              </FraudPreprocessResult>
              <FraudPostprocessResult>
                <Message>Review</Message>
              </FraudPostprocessResult>
              <Message>Under review by Fraud Service</Message>
              <PNRef>A71A7B022DC0</PNRef>
              <AuthCode>907PNI</AuthCode>
            </TransactionResult>
          </TransactionResults>
        </ResponseData>
      </XMLPayResponse>
    XML
  end

  def successful_duplicate_response
    <<~XML
      <?xml version="1.0"?>
      <XMLPayResponse xmlns="http://www.verisign.com/XMLPay">
      	<ResponseData>
      		<Vendor>ActiveMerchant</Vendor>
      		<Partner>paypal</Partner>
      		<TransactionResults>
      			<TransactionResult Duplicate="true">
      				<Result>0</Result>
      				<ProcessorResult>
      					<AVSResult>A</AVSResult>
      					<CVResult>M</CVResult>
      					<HostCode>A</HostCode>
      				</ProcessorResult>
      				<IAVSResult>N</IAVSResult>
      				<AVSResult>
      					<StreetMatch>Match</StreetMatch>
      					<ZipMatch>No Match</ZipMatch>
      				</AVSResult>
      				<CVResult>Match</CVResult>
      				<Message>Approved</Message>
      				<PNRef>V18A0CBB04CF</PNRef>
      				<AuthCode>692PNI</AuthCode>
      				<ExtData Name="DATE_TO_SETTLE" Value="2007-11-28 10:53:50"/>
      			</TransactionResult>
      		</TransactionResults>
      	</ResponseData>
      </XMLPayResponse>
    XML
  end

  def verbose_transaction_response
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <XMLPayResponse  xmlns="http://www.paypal.com/XMLPay">
        <ResponseData>
          <Vendor>ActiveMerchant</Vendor>
          <Partner>paypal</Partner>
          <TransactionResults>
            <TransactionResult>
              <Result>0</Result>
              <ProcessorResult>
                <AVSResult>U</AVSResult>
                <CVResult>M</CVResult>
                <HostCode>A</HostCode>
              </ProcessorResult>
              <FraudPreprocessResult>
                <Message>No Rules Triggered</Message>
              </FraudPreprocessResult>
              <FraudPostprocessResult>
                <Message>No Rules Triggered</Message>
              </FraudPostprocessResult>
              <IAVSResult>X</IAVSResult>
              <AVSResult>
                <StreetMatch>Service Not Available</StreetMatch>
                <ZipMatch>Service Not Available</ZipMatch>
              </AVSResult>
              <CVResult>Match</CVResult>
              <Message>Approved</Message>
              <PNRef>A70A6C93C4C8</PNRef>
              <AuthCode>242PNI</AuthCode>
              <Amount>1.00</Amount>
              <VisaCardLevel>12</VisaCardLevel>
              <TransactionTime>2014-06-25 09:33:41</TransactionTime>
              <Account>4242</Account>
              <ExpirationDate>0714</ExpirationDate>
              <CardType>0</CardType>
              <PayPalResult>
                <FeeAmount>0</FeeAmount>
                <Name>Longbob</Name>
                <Lastname>Longsen</Lastname>
              </PayPalResult>
            </TransactionResult>
          </TransactionResults>
        </ResponseData>
      </XMLPayResponse>
    XML
  end

  def three_d_secure_option(options: {})
    {
      three_d_secure: {
        authentication_id: 'QvDbSAxSiaQs241899E0',
        authentication_response_status: SUCCESSFUL_AUTHENTICATION_STATUS,
        pareq: 'pareq block',
        acs_url: 'https://bankacs.bank.com/ascurl',
        eci: '02',
        cavv: 'jGvQIvG/5UhjAREALGYa6Vu/hto=',
        xid: 'UXZEYlNBeFNpYVFzMjQxODk5RTA='
      }.
        merge(options).
        compact
    }
  end

  def assert_three_d_secure_via_mpi(xml_doc, tx_type: 'Authorization', expected_version: nil, expected_ds_transaction_id: nil)
    [
      { name: 'AUTHENTICATION_STATUS', expected: SUCCESSFUL_AUTHENTICATION_STATUS },
      { name: 'AUTHENTICATION_ID', expected: 'QvDbSAxSiaQs241899E0' },
      { name: 'ECI', expected: '02' },
      { name: 'CAVV', expected: 'jGvQIvG/5UhjAREALGYa6Vu/hto=' },
      { name: 'XID', expected: 'UXZEYlNBeFNpYVFzMjQxODk5RTA=' },
      { name: 'THREEDSVERSION', expected: expected_version },
      { name: 'DSTRANSACTIONID', expected: expected_ds_transaction_id }
    ].each do |item|
      assert_equal item[:expected], REXML::XPath.first(xml_doc, threeds_xpath_for_extdata(item[:name], tx_type:))
    end
  end

  def assert_three_d_secure(
    xml_doc,
    buyer_auth_result_path,
    expected_status: SUCCESSFUL_AUTHENTICATION_STATUS,
    expected_authentication_status: nil,
    expected_version: nil,
    expected_ds_transaction_id: nil
  )
    assert_text_value_or_nil expected_status, REXML::XPath.first(xml_doc, "#{buyer_auth_result_path}/Status")
    assert_text_value_or_nil(expected_authentication_status, REXML::XPath.first(xml_doc, "#{buyer_auth_result_path}/AuthenticationStatus"))
    assert_text_value_or_nil 'QvDbSAxSiaQs241899E0', REXML::XPath.first(xml_doc, "#{buyer_auth_result_path}/AuthenticationId")
    assert_text_value_or_nil 'pareq block', REXML::XPath.first(xml_doc, "#{buyer_auth_result_path}/PAReq")
    assert_text_value_or_nil 'https://bankacs.bank.com/ascurl', REXML::XPath.first(xml_doc, "#{buyer_auth_result_path}/ACSUrl")
    assert_text_value_or_nil '02', REXML::XPath.first(xml_doc, "#{buyer_auth_result_path}/ECI")
    assert_text_value_or_nil 'jGvQIvG/5UhjAREALGYa6Vu/hto=', REXML::XPath.first(xml_doc, "#{buyer_auth_result_path}/CAVV")
    assert_text_value_or_nil 'UXZEYlNBeFNpYVFzMjQxODk5RTA=', REXML::XPath.first(xml_doc, "#{buyer_auth_result_path}/XID")
    assert_text_value_or_nil(expected_version, REXML::XPath.first(xml_doc, "#{buyer_auth_result_path}/ThreeDSVersion"))
    assert_text_value_or_nil(expected_ds_transaction_id, REXML::XPath.first(xml_doc, "#{buyer_auth_result_path}/DSTransactionID"))
  end

  def assert_text_value_or_nil(expected_text_value, xml_element)
    if expected_text_value
      assert_equal expected_text_value, xml_element.text
    else
      assert_nil xml_element
    end
  end

  def xpath_prefix_for_transaction_type(tx_type)
    return '/XMLPayRequest/RequestData/Transactions/Transaction/Authorization/' unless tx_type == 'Sale'

    '/XMLPayRequest/RequestData/Transactions/Transaction/Sale/'
  end

  def threeds_xpath_for_extdata(attr_name, tx_type: 'Authorization')
    xpath_prefix = xpath_prefix_for_transaction_type(tx_type)
    %(string(#{xpath_prefix}/PayData/ExtData[@Name='#{attr_name}']/@Value))
  end

  def authorize_buyer_auth_result_path
    xpath_prefix = xpath_prefix_for_transaction_type('Authorization')
    "#{xpath_prefix}/PayData/Tender/Card/BuyerAuthResult"
  end

  def purchase_buyer_auth_result_path
    xpath_prefix = xpath_prefix_for_transaction_type('Sale')
    "#{xpath_prefix}/PayData/Tender/Card/BuyerAuthResult"
  end
end
