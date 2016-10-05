--[[
    Copyright 2016 Vadim Peretokin. All Rights Reserved.

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

         http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS-IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
]]

local config      = require("lapis.config").get()
local db = require("lapis.db")
local to_json     = require("lapis.util").to_json
local from_json   = require("lapis.util").from_json
local to_fhir_json = require("fhirformats").to_json
local to_fhir_xml = require("fhirformats").to_xml
local inspect     = require("inspect")
local date        = require("date")
local sformat = string.format

local routes = {}

local unpickle_fhirbase_result = function(result, fhirbase_function)
  return select(2, next(result))[fhirbase_function]
end

local types = {
  ["application/json"]      = "json",
  ["application/json+fhir"] = "json",
  ["application/fhir+json"] = "json",
  ["application/xml"]       = "xml",
  ["application/xml+fhir"]  = "xml",
  ["application/fhir+xml"]  = "xml",
  ["html"]                  = "xml",
  ["json"]                  = "json",
  ["text/html"]             = "xml",
  ["text/xml"]              = "xml",
  ["xml"]                   = "xml",
}
local from_types = {
  json = "application/fhir+json",
  xml = "application/fhir+xml"
}

-- determine content type from headers or optionally the resource
-- for more heuristics, if one is available
local function get_resource_type(content_type, resource)
  -- strip out the ;charset=UTF-8 and whatever else, no usecase for handling that yet
  if content_type then
    content_type = content_type:match("^([^;]+)")
  end

  if content_type and types[content_type] then return types[content_type]
  elseif resource and resource:find("http://hl7.org/fhir") then return "xml"
  elseif resource and resource:find("resourceType") then return "json"
  else return "json" end
end

local function read_resource(resource)
  if get_resource_type(ngx.req.get_headers()["content-type"], resource) == "xml" then
    return from_json(to_fhir_json(resource))
  end

  return from_json(resource)
end

local function save_resource(resource, fhir_type)
  -- don't pass resource, since it's the one we're getting back from fhirbase
  if fhir_type == "xml" then
    return to_fhir_xml(to_json(resource))
  end

  return to_json(resource)
end

local function make_return_content_type(fhir_type)
  return from_types[fhir_type] or from_types.json
end

-- returns the servers base url, based on a URL that was sent to it
local function get_base_url(self)
  local parsed_url = self.req.parsed_url
  local base_url = parsed_url.scheme .. '://' .. parsed_url.host.. ((parsed_url.port == nil or parsed_url.port == 80 or parsed_url.port == 443) and "" or ':'.. parsed_url.port)
  return base_url
end

-- given a resource and desired http status code, creates a response in the right output format (xml or json) with the correct http headers
-- desired http status code will be overwritten if there is an error
local function make_response(resource, http_status_code, headers)
  local desired_fhir_type = get_resource_type(ngx.req.get_headers()["accept"])

  if resource and resource.resourceType == "OperationOutcome" and resource.issue[1].extension then
    http_status_code = resource.issue[1].extension[1].code or resource.issue[1].extension[1].valueString
  end

  return {save_resource(resource, desired_fhir_type), layout = false, content_type = make_return_content_type(desired_fhir_type), status = (http_status_code and http_status_code or 200), headers = headers}
end

routes.metadata = function ()
  local operation = {name = "conformance", definition = "http://hl7.org/fhir/http.html#conformance", fhirbase_function = "fhir_conformance"}

  local res = db.select(operation.fhirbase_function .. "(?);", to_json({default = "values"}))

  return make_response(unpickle_fhirbase_result(res, operation.fhirbase_function))
end

routes.create_resource = function(self)
  local operation = {name = "create", definition = "http://hl7.org/fhir/http.html#create", fhirbase_function = "fhir_create_resource"}

  -- TODO make http://hl7.org/fhir/http.html#ccreate work


  ngx.req.read_body()
  local data = read_resource(ngx.req.get_body_data())
  local wrapped_data = {resource = data}

  local res = db.select(operation.fhirbase_function .. "(?);", to_json(wrapped_data))

  -- get the base URL and construct a Location header
  local Location
  local base_url = get_base_url(self)
  local resource = unpickle_fhirbase_result(res, operation.fhirbase_function)
  -- only do this for a resource that was created - ignore OperationOutcome resources
  if resource.meta then
    Location = sformat("%s/%s/%s/_history/%s", base_url, resource.resourceType, resource.id, resource.meta.versionId)
  end

  return make_response(unpickle_fhirbase_result(res, operation.fhirbase_function), 201, {Location = Location})
end

routes.read_resource = function(self)
  local operation = {name = "read", definition = "http://hl7.org/fhir/http.html#read", fhirbase_function = "fhir_read_resource"}

  local res = db.select(operation.fhirbase_function .. "(?);", to_json({resourceType = self.params.type, id = self.params.id}))

  return make_response(unpickle_fhirbase_result(res, operation.fhirbase_function))
end

routes.vread_resource = function(self)
  local operation = {name = "vread", definition = "http://hl7.org/fhir/http.html#vread", fhirbase_function = "fhir_vread_resource"}

  local res = db.select(operation.fhirbase_function .. "(?);", to_json({resourceType = self.params.type, id = self.params.id, versionId = self.params.versionId}))

  return make_response(unpickle_fhirbase_result(res, operation.fhirbase_function))
end

routes.update_resource = function(self)
  local operation = {name = "update", definition = "http://hl7.org/fhir/http.html#update", fhirbase_function = "fhir_update_resource"}

  ngx.req.read_body()
  local body_data = ngx.req.get_body_data()
  if not body_data then
    return { json = config.canned_responses.handle_missing_body[1], status = config.canned_responses.handle_missing_body.status}
  end

  local data = read_resource(body_data)
  local wrapped_data = {resource = data}

  local res = db.select(operation.fhirbase_function .. "(?);", to_json(wrapped_data))

  -- construct the appropriate Last-Modified, ETag, and Location headers
  local last_modified, etag, location
  local base_url = get_base_url(self)
  local resource = unpickle_fhirbase_result(res, operation.fhirbase_function)
  -- only do this for a resource that was created - ignore OperationOutcome resources
  if resource.meta then
    last_modified = date(resource.meta.lastUpdated):fmt("${http}")
    etag = sformat('W/"%s"', resource.meta.versionId)
    location = sformat("%s/%s/%s/_history/%s", base_url, resource.resourceType, resource.id, resource.meta.versionId)
  end

  return make_response(unpickle_fhirbase_result(res, operation.fhirbase_function), 200, {["Last-Modified"] = last_modified, ["ETag"] = etag, ["Location"] = location})
end

routes.delete_resource = function(self)
  local operation = {name = "delete", definition = "http://hl7.org/fhir/http.html#delete", fhirbase_function = "fhir_delete_resource"}

  local res = db.select(operation.fhirbase_function .. "(?);", to_json({resourceType = self.params.type, id = self.params.id}))

  return make_response(unpickle_fhirbase_result(res, operation.fhirbase_function), 204)
end

local function populate_bundle_fullUrls(self, bundle)
  local base_url = get_base_url(self)
  -- only do this for a resource that was created - ignore OperationOutcome resources
  if bundle.resourceType == "Bundle" then
    for i = 1, #bundle.entry do
      local found_resource = bundle.entry[i].resource

      if found_resource then -- deleted resources in history bundle won't have a resource element, so skip creation of a fullUrl
        local full_url = sformat("%s/%s/%s", base_url, found_resource.resourceType, found_resource.id)

        bundle.entry[i].fullUrl = full_url
      end
    end
  end

  return bundle
end

routes.get_resource_history = function(self)
  local operation = {name = "delete", definition = "https://hl7-fhir.github.io/http.html#history", fhirbase_function = "fhir_resource_history"}

  local res = db.select(operation.fhirbase_function .. "(?);", to_json({resourceType = self.params.type, id = self.params.id}))

  local bundle = unpickle_fhirbase_result(res, operation.fhirbase_function)

  -- fill in the fullUrl fields in the Bundle response
  bundle = populate_bundle_fullUrls(self, bundle)

  return make_response(bundle)
end

routes.search = function(self)
  local operation = {name = "search", definition = "http://hl7.org/fhir/http.html#search", fhirbase_function = "fhir_search"}

  local res = db.select(operation.fhirbase_function .. "(?);", to_json({resourceType = self.params.type, queryString = self.req.parsed_url.query}))

  local bundle = unpickle_fhirbase_result(res, operation.fhirbase_function)

  -- fill in the fullUrl fields in the Bundle response
  bundle = populate_bundle_fullUrls(self, bundle)

  return make_response(bundle)
end

return routes
