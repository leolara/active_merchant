require 'nokogiri'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class MoneiGateway < Gateway
      self.test_url = 'https://test.ctpe.io/payment/ctpe'
      self.live_url = 'https://ctpe.io/payment/ctpe'

      self.supported_countries = ['ES']
      self.default_currency = 'EUR'
      self.supported_cardtypes = [:visa, :master, :maestro]

      self.homepage_url = 'http://www.monei.net/'
      self.display_name = 'Monei'

      def initialize(options={})
        requires!(options, :sender_id, :channel_id, :login, :pwd)
        super
      end

      def purchase(money, credit_card, options={})
        execute_new_order(:purchase, money, credit_card, options)
      end

      def authorize(money, credit_card, options={})
        execute_new_order(:authorize, money, credit_card, options)
      end

      def capture(money, authorization, options={})
        execute_authorization(:capture, money, authorization, options)
      end

      def refund(money, authorization, options={})
        execute_authorization(:refund, money, authorization, options)
      end

      def void(authorization, options={})
        execute_authorization(:void, nil, authorization, options)
      end

      def verify(credit_card, options={})
        MultiResponse.run(:use_first_response) do |r|
          r.process { authorize(100, credit_card, options) }
          r.process(:ignore_result) { void(r.authorization, options) }
        end
      end

      private

      def execute_new_order(action, money, credit_card, options)
        request = build_request do |xml|
          add_identification_new_order(xml, options)
          add_payment(xml, action, money, options)
          add_account(xml, credit_card)
          add_customer(xml, credit_card, options)
        end

        commit(request)
      end


      def execute_authorization(action, money, authorization, options)
        request = build_request do |xml|
          add_identification_authorization(xml, authorization, options)
          add_payment(xml, action, money, options)
        end

        commit(request)
      end

      def build_request
        builder = Nokogiri::XML::Builder.new(:encoding => 'UTF-8') do |xml|
          xml.Request(:version => "1.0") do

            xml.Header { xml.Security(:sender => @options[:sender_id]) }

            xml.Transaction(:mode => test? ? 'CONNECTOR_TEST' : 'LIVE', :response => 'SYNC', :channel => @options[:channel_id]) do
              xml.User(:login => @options[:login], :pwd => @options[:pwd])

              yield xml
            end

          end
        end
        builder.to_xml
      end

      def add_identification_new_order(xml, options)
        requires!(options, :order_id)
        xml.Identification do
          xml.TransactionID options[:order_id]
        end
      end

      def add_identification_authorization(xml, authorization, options)
        xml.Identification do
          xml.ReferenceID authorization
          xml.TransactionID options[:order_id]
        end
      end

      def add_payment(xml, action, money, options)
        code = tr_payment_code action

        xml.Payment(:code => code) do
          xml.Presentation do
            xml.Amount amount(money)
            xml.Currency options[:currency] || currency(money)
            xml.Usage options[:description] || options[:order_id]
          end unless money.nil?
        end
      end

      def add_account(xml, credit_card)
        xml.Account do
          xml.Holder credit_card.name
          xml.Number credit_card.number
          xml.Brand credit_card.brand.upcase
          xml.Expiry(:month => credit_card.month, :year => credit_card.year)
          xml.Verification credit_card.verification_value
        end
      end

      def add_customer(xml, credit_card, options)
        requires!(options, :billing_address)
        address = options[:billing_address]
        xml.Customer do

          xml.Name do
            xml.Given options[:given] || credit_card.first_name
            xml.Family options[:family] || credit_card.last_name
          end
          xml.Address do
            xml.Street address[:address1].to_s
            xml.Zip address[:zip].to_s
            xml.City address[:city].to_s
            xml.State address[:state] if address.has_key? :state
            xml.Country address[:country].to_s
          end
          xml.Contact do
            xml.Email options[:email] || 'noemail@monei.net'
            xml.Ip options[:ip] || '0.0.0.0'
          end

        end
      end

      def parse(body)
        xml = Nokogiri::XML(body)

        {
            :unique_id => xml.xpath("//Response/Transaction/Identification/UniqueID").text,
            :status => (tr_status_code xml.xpath("//Response/Transaction/Processing/Status/@code").text),
            :reason => (tr_status_code xml.xpath("//Response/Transaction/Processing/Reason/@code").text),
            :message => xml.xpath("//Response/Transaction/Processing/Return").text
        }
      end

      def commit(xml)
        url = (test? ? test_url : live_url)

        response = parse(ssl_post(url, post_data(xml), 'Content-Type' => 'application/x-www-form-urlencoded;charset=UTF-8'))

        Response.new(
          success_from(response),
          message_from(response),
          response,
          authorization: authorization_from(response),
          test: test?
        )
      end

      def success_from(response)
        response[:status] == :success or response[:status] == :new
      end

      def message_from(response)
        response[:message]
      end

      def authorization_from(response)
        response[:unique_id]
      end

      def post_data(xml)
        "load=#{CGI.escape(xml)}"
      end

      def tr_status_code(code)
        {
            '00' => :success,
            '40' => :neutral,
            '59' => :waiting_bank,
            '60' => :rejected_bank,
            '64' => :waiting_risk,
            '65' => :rejected_risk,
            '70' => :rejected_validation,
            '80' => :waiting,
            '90' => :new
        }[code]
      end

      def tr_payment_code(action)
        {
            :purchase => 'CC.DB',
            :authorize => 'CC.PA',
            :capture => 'CC.CP',
            :refund => 'CC.RF',
            :void => 'CC.RV'
        }[action]
      end
    end
  end
end
