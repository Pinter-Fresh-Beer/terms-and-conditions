#!/usr/bin/env ruby

require 'json'
require 'net/http'
require 'psych'
require 'uri'
require 'unicode_normalize'

UPSERT_METAOBJECT_MUTATION = <<~GRAPHQL
  mutation UpsertMetaobject($handle: MetaobjectHandleInput!, $metaobject: MetaobjectUpsertInput!) {
    metaobjectUpsert(handle: $handle, metaobject: $metaobject) {
      metaobject {
        id
        handle
      }
      userErrors {
        field
        message
        code
      }
    }
  }
GRAPHQL

def env!(key, default = nil)
  value = ENV[key]
  value = default if value.nil? || value.empty?
  raise "Missing required environment variable: #{key}" if value.nil? || value.empty?

  value
end

def handleize(value)
  value
    .unicode_normalize(:nfkd)
    .encode('ASCII', replace: '')
    .downcase
    .gsub(/['’]/, '')
    .gsub(/[^a-z0-9]+/, '-')
    .gsub(/^-+|-+$/, '')
end

def rich_text_json(text)
  paragraphs = text.to_s.strip.split(/\n{2,}/).map do |paragraph|
    normalized = paragraph.split("\n").map(&:strip).reject(&:empty?).join(' ')
    next if normalized.empty?

    {
      type: 'paragraph',
      children: [
        {
          type: 'text',
          value: normalized
        }
      ]
    }
  end.compact

  { type: 'root', children: paragraphs }.to_json
end

def shopify_graphql(endpoint, token, query, variables)
  uri = URI(endpoint)
  request = Net::HTTP::Post.new(uri)
  request['Content-Type'] = 'application/json'
  request['X-Shopify-Access-Token'] = token
  request.body = JSON.generate({ query: query, variables: variables })

  response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
    http.request(request)
  end

  raise "Shopify API request failed with status #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

  payload = JSON.parse(response.body)
  raise "Shopify GraphQL errors: #{payload['errors'].to_json}" if payload['errors']

  payload['data']
end

def upsert_metaobject(endpoint, token, type:, handle:, fields:)
  data = shopify_graphql(
    endpoint,
    token,
    UPSERT_METAOBJECT_MUTATION,
    {
      handle: {
        type: type,
        handle: handle
      },
      metaobject: {
        fields: fields
      }
    }
  )

  payload = data.fetch('metaobjectUpsert')
  user_errors = payload.fetch('userErrors')

  unless user_errors.empty?
    raise "Shopify user errors for #{type}/#{handle}: #{user_errors.to_json}"
  end

  payload.fetch('metaobject')
end

source_file = env!('FAQS_SOURCE_PATH', 'faqs-lp-usa.yml')
group_handle = env!('SHOPIFY_FAQ_GROUP_HANDLE', 'faqs-lp-usa')
group_internal_name = env!('SHOPIFY_FAQ_GROUP_INTERNAL_NAME', 'faqs_lp_usa')
shop_domain = env!('SHOPIFY_STORE_DOMAIN')
shopify_token = env!('SHOPIFY_ADMIN_ACCESS_TOKEN')
api_version = env!('SHOPIFY_API_VERSION', '2026-04')

unless File.exist?(source_file)
  raise "FAQ source file not found: #{source_file}"
end

yaml = Psych.safe_load_file(source_file, aliases: false)
faqs = yaml.is_a?(Hash) ? yaml['faqs'] : nil

unless faqs.is_a?(Array) && !faqs.empty?
  raise "Expected #{source_file} to contain a non-empty 'faqs' array"
end

endpoint = "https://#{shop_domain}/admin/api/#{api_version}/graphql.json"

faq_ids = faqs.map.with_index do |faq, index|
  question = faq['question']&.strip
  answer = faq['answer']&.to_s&.strip

  raise "FAQ at index #{index} is missing question" if question.nil? || question.empty?
  raise "FAQ at index #{index} is missing answer" if answer.nil? || answer.empty?

  handle = handleize(question)
  raise "Could not derive handle for FAQ question: #{question}" if handle.empty?

  metaobject = upsert_metaobject(
    endpoint,
    shopify_token,
    type: 'faq_item',
    handle: handle,
    fields: [
      { key: 'question', value: question },
      { key: 'answer', value: rich_text_json(answer) }
    ]
  )

  metaobject.fetch('id')
end

upsert_metaobject(
  endpoint,
  shopify_token,
  type: 'faq_group',
  handle: group_handle,
  fields: [
    { key: 'internal_name', value: group_internal_name },
    { key: 'faqs', value: faq_ids.to_json }
  ]
)

puts "Synced #{faq_ids.length} FAQs from #{source_file} to faq_group/#{group_handle}"
