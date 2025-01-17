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
local unescape    = require("lapis.util").unescape
local from_json   = require("lapis.util").from_json
local to_fhir_json = require("fhirformats").to_json
local to_fhir_xml = require("fhirformats").to_xml
local get_fhir_definition = require("fhirformats").get_fhir_definition
local inspect     = require("inspect")
local date        = require("date")
local stringx     = require("pl.stringx")
local tablex      = require("pl.tablex")
local sformat = string.format

local routes = {}

-- given a raw JSON response from fhirbase and the fhirbase function that generated it,
-- returns the wrapped resource data inside
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

-- as FHIR loves to put data in {key="key for data", value="value"} tables,
-- this helper function scans through a table of tables for the given key.
-- Returns the matching values as a table or nil if none
local function get_value_by_key(data, indexkey, indexvalue, valuekey)
  assert(type(data) == "table")
  local results = {}

  for i = 1, #data do
    if data[i][indexkey] == indexvalue then
      results[#results+1] = data[i][valuekey]
    end
  end

  return results[1] and results or nil
end

-- returns the data for a request parameter, if it exists
local function get_req_param(self, wanted_param)
  if self.req.parsed_url.query and self.req.parsed_url.query:find(wanted_param, 1, true) then
    local query = unescape(self.req.parsed_url.query)
    local parameters = stringx.split(query, "&")
    for i = 1, #parameters do
      local param = parameters[i]
      if string.find(param, wanted_param) then
        local param_data = string.match(param, wanted_param.."=(.*)")
        return param_data
      end
    end
  end
end

-- determines the appropriate request response content type, based in _format or headers
local function get_return_content_type(self, content_type)
  -- first, check if a _format header is present
  local format = get_req_param(self, "_format")
  if format then return types[format] end

  -- if no _format is found, try to match it via Accept header
  return get_resource_type(content_type)
end

-- given a json resource from fhirbase, converts it to xml if desired by the requster
-- returns resouce as a string
local function save_resource(resource, fhir_type)
  -- don't pass resource, since it's the one we're getting back from fhirbase
  if fhir_type == "xml" then
    return to_fhir_xml(to_json(resource))
  end

  return to_json(resource)
end

local function make_return_content_type(fhir_type)
  local content_type = from_types[fhir_type] or from_types.json

  -- also add the charset back in if it was used in either Accept or Accept-Charset headers
  local headers = ngx.req.get_headers()
  if (headers["accept"] and headers["accept"]:lower():find("charset=utf-8", 1, true))
    or (headers["accept-charset"] and headers["accept-charset"]:lower():find("utf-8", 1, true)) then
    content_type = sformat("%s;%s", content_type, "charset=UTF-8")
  end

  return content_type
end

-- returns the servers base url, based on a URL that was sent to it
local function get_base_url(self)
  local parsed_url = self.req.parsed_url
  local base_url = parsed_url.scheme .. '://' .. parsed_url.host.. ((parsed_url.port == nil or parsed_url.port == 80 or parsed_url.port == 443) and "" or ':'.. parsed_url.port)
  return base_url
end

-- insert the string arguments given a given a canned response
local function populate_canned_response(resource, ...)
  local canned_resource_copy = tablex.deepcopy(resource)
  canned_resource_copy.text.div = string.format(canned_resource_copy.text.div, ...)
  canned_resource_copy.issue[1].diagnostics = string.format(canned_resource_copy.issue[1].diagnostics, ...)

  return canned_resource_copy
end

-- given a resource and desired http status code, creates a response in the right output format (xml or json) with the correct http headers
-- desired http status code will be overwritten if there is an error
-- resource output will be determined by the presence or lack of a Prefer header
-- 'headers' are custom headers to add to the response
local function make_response(self, resource, http_status_code, headers)
  local request_headers = ngx.req.get_headers()
  local desired_fhir_type = get_return_content_type(self, request_headers["accept"])

  if resource and resource.resourceType == "OperationOutcome" and resource.issue and resource.issue[1].extension then
    http_status_code = resource.issue[1].extension[1].code or resource.issue[1].extension[1].valueString
  elseif resource and resource.resourceType == "OperationOutcome" and resource.issue and tonumber(resource.issue[1].code) then -- sometimes it doesn't return anything in the extension
    http_status_code = resource.issue[1].code
  end

  local body_output, content_type
  if request_headers["Prefer"] and request_headers["Prefer"] == "return=minimal" then
    body_output = ""
    -- leave content_type nil, so none is sent... doesn't actually work quite right
    -- so we workaround by removing it after Lapis runs (https://github.com/leafo/lapis/issues/485)
    content_type = config.no_return_content_type
  elseif request_headers["Prefer"] and request_headers["Prefer"] == "return=OperationOutcome" then
    body_output = to_json(config.canned_responses.prefer_successful_operationoutcome[1])
    content_type = make_return_content_type(desired_fhir_type)
  else
    body_output = save_resource(resource, desired_fhir_type)
    content_type = make_return_content_type(desired_fhir_type)
  end

  return {body_output, layout = false, content_type = content_type, status = (http_status_code and http_status_code or 200), headers = headers}
end

routes.before_filter = function(self)
  if self.params.type then
    if not ngx.shared.known_resources:get(self.params.type) then
      self.resource_list = ngx.shared.known_resources:get_keys()

      self:write(make_response(self, populate_canned_response(config.canned_responses.handle_404[1], table.concat(self.resource_list, ', ')), config.canned_responses.handle_404.status))
    end
  end
end

routes.handle_404 = function(self)
  self.resource_list = ngx.shared.known_resources:get_keys()

  return(make_response(self, populate_canned_response(config.canned_responses.handle_404[1], table.concat(self.resource_list, ', ')), config.canned_responses.handle_404.status))
end

-- given a CapabilityStatement resource, populate all resources
-- we have with supported search parameters

-- returns the same resource back but now with search parameters
local function populate_metadata_searchparams(capabilitystatement)
  -- query fhirbase once (for efficiency reasons) for all the search parameters we know of
  local result_known_search_params = db.select("fhir_search(?);", to_json({resourceType = "SearchParameter", queryString = "_count=1000000"}))
  local known_search_params = unpickle_fhirbase_result(result_known_search_params, "fhir_search")


  -- create a small cache of resourcename = resourcetable in conformance for easy access
  local function make_capstatementmap()
    local capstatementmap = {}
    for i = 1, #capabilitystatement.rest[1].resource do
      local resource = capabilitystatement.rest[1].resource[i]
      capstatementmap[resource.type] = resource
    end

    return capstatementmap
  end

  local capstatementmap = make_capstatementmap()

  -- loop through all search params and update resources in capabilitystatement accordingly
  for i = 1, #known_search_params.entry do
    local search_parameter_resource = known_search_params.entry[i].resource

    -- find the correct CapabilityStatement resource declaration and create a searchParam field in it
    local corresponding_resource_in_capabilitystatement = capstatementmap[search_parameter_resource.base]
    corresponding_resource_in_capabilitystatement.searchParam = corresponding_resource_in_capabilitystatement.searchParam or {}
    corresponding_resource_in_capabilitystatement.searchParam[#corresponding_resource_in_capabilitystatement.searchParam+1] = {}
    local searchParam = corresponding_resource_in_capabilitystatement.searchParam[#corresponding_resource_in_capabilitystatement.searchParam]

    searchParam.name = search_parameter_resource.name
    searchParam.definition = search_parameter_resource.url
    searchParam.type = search_parameter_resource.type
    searchParam.target = search_parameter_resource.target
    searchParam.modifier = {}

    if searchParam.type ~= "composite" then
      searchParam.modifier[#searchParam.modifier+1] = "missing"
    end
    if searchParam.type == "string" then
      searchParam.modifier[#searchParam.modifier+1] = "exact"
      searchParam.modifier[#searchParam.modifier+1] = "contains"
    end
    if searchParam.type == "uri" then
      searchParam.modifier[#searchParam.modifier+1] = "below"
    end


    -- searchParam.chain
  end

  return capabilitystatement
end

routes.metadata = function (self)
  local operation = {name = "conformance", definition = "http://hl7.org/fhir/http.html#conformance", fhirbase_function = "fhir_conformance"}

  local res = db.select(operation.fhirbase_function .. "(?);", to_json({default = "values"}))

  local conformance = unpickle_fhirbase_result(res, operation.fhirbase_function)

  -- add conformance statements to what dryfhir supports on top of fhirbase
  conformance.format = {"xml", "json"}
  conformance.status = config.fhir_conformance_status
  conformance.experimental = config.fhir_conformance_experimental
  conformance.kind = "instance"

  conformance.software.name = "DryFHIR"

  -- mention we support conditional create and update
  for _, resource in pairs(conformance.rest[1].resource) do
    resource.conditionalCreate = true
    resource.conditionalUpdate = true

    if not config.fhir_multiple_conditional_delete then
      resource.conditionalDelete = "single"
    else
      resource.conditionalDelete = "multiple"
    end
  end

  conformance = populate_metadata_searchparams(conformance)

  return make_response(self, conformance)
end

routes.create_resource = function(self)
  local operation = {name = "create", definition = "http://hl7.org/fhir/http.html#create", fhirbase_function = "fhir_create_resource"}

  ngx.req.read_body()
  local data = read_resource(ngx.req.get_body_data())
  local wrapped_data = {resource = data}

  wrapped_data.ifNoneExist = ngx.req.get_headers()["if-none-exist"]

  -- check if we need to return a 200 header for a conditional create, when 1 resource instance already existed and nothing happened
  local http_status_code = 201
  if wrapped_data.ifNoneExist then
    local check_creation = db.select("fhir_search(?);", to_json({resourceType = self.params.type, queryString = wrapped_data.ifNoneExist}))
    local result_bundle = unpickle_fhirbase_result(check_creation, "fhir_search")
    if result_bundle.total == 1 then
      http_status_code = 200
    end
  end

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

  -- return make_response(self, config.canned_responses.conditional_create_resource_already_exists[1], http_status_code, {["Last-Modified"] = last_modified, ["ETag"] = etag, ["Location"] = location})
  return make_response(self, http_status_code == 200 and config.canned_responses.conditional_create_resource_already_exists[1] or unpickle_fhirbase_result(res, operation.fhirbase_function), http_status_code, {["Last-Modified"] = last_modified, ["ETag"] = etag, ["Location"] = location})
end

routes.read_resource = function(self)
  local operation = {name = "read", definition = "http://hl7.org/fhir/http.html#read", fhirbase_function = "fhir_read_resource"}
  local resource

  local req_summary = get_req_param(self, "_summary")
  -- fhirbase doesn't support read with a summary, but it does support search for summary=true,
  -- so work around a read by using a search
  if req_summary and req_summary ~= "false" then
    if req_summary == "true" then
      local res = db.select("fhir_search(?);", to_json({resourceType = self.params.type, queryString = sformat("_id=%s&_summary=%s", self.params.id, req_summary)}))
      local bundle = unpickle_fhirbase_result(res, "fhir_search")

      if bundle.total == 1 then
        resource = bundle.entry[1].resource
      end
    elseif req_summary == "data" then
      local res = db.select(operation.fhirbase_function .. "(?);", to_json({resourceType = self.params.type, id = self.params.id}))
      resource = unpickle_fhirbase_result(res, operation.fhirbase_function)
      resource.text = nil
    elseif req_summary == "text" then
      local res = db.select(operation.fhirbase_function .. "(?);", to_json({resourceType = self.params.type, id = self.params.id}))
      local unpruned_resource = unpickle_fhirbase_result(res, operation.fhirbase_function)

      -- "Return only the "text" element, the 'meta' element, and any mandatory elements"
      resource = {}
      for element, data in pairs(unpruned_resource) do
        if element == "resourceType"
        or element == "meta"
        or element == "id"
        or element == "text"
        or get_fhir_definition(unpruned_resource.resourceType, element)._min == 1 then
          resource[element] = data
        end
      end
    end

    if resource then
      -- add the SUBSETTED tag
      resource.meta.security = resource.meta.security or {}
      resource.meta.security[#resource.meta.security+1] = {
        system = "http://hl7.org/fhir/v3/ObservationValue",
        code = "SUBSETTED",
        display = "subsetted"
      }
    end
  end

  -- if we didn't have a summary or nothing was found in the bundle for some reason, fallback to a plain GET
  if not resource then
    local res = db.select(operation.fhirbase_function .. "(?);", to_json({resourceType = self.params.type, id = self.params.id}))
    resource = unpickle_fhirbase_result(res, operation.fhirbase_function)
  end

  -- construct the appropriate Last-Modified, ETag, and Location headers
  local last_modified, etag, location
  local base_url = get_base_url(self)
  -- only do this for a resource that was created - ignore OperationOutcome resources
  if resource.meta then
    last_modified = date(resource.meta.lastUpdated):fmt("${http}")
    etag = sformat('W/"%s"', resource.meta.versionId)
    location = sformat("%s/%s/%s/_history/%s", base_url, resource.resourceType, resource.id, resource.meta.versionId)
  end

  return make_response(self, resource, 200, {["Last-Modified"] = last_modified, ["ETag"] = etag, ["Location"] = location})
end

routes.vread_resource = function(self)
  local operation = {name = "vread", definition = "http://hl7.org/fhir/http.html#vread", fhirbase_function = "fhir_vread_resource"}

  local res = db.select(operation.fhirbase_function .. "(?);", to_json({resourceType = self.params.type, id = self.params.id, versionId = self.params.versionId}))

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

  return make_response(self, unpickle_fhirbase_result(res, operation.fhirbase_function), 200, {["Last-Modified"] = last_modified, ["ETag"] = etag, ["Location"] = location})
end

routes.update_resource = function(self)
  local operation = {name = "update", definition = "http://hl7.org/fhir/http.html#update", fhirbase_function = "fhir_update_resource"}

  ngx.req.read_body()
  local body_data = ngx.req.get_body_data()
  if not body_data then
    return make_response(self, config.canned_responses.handle_missing_body[1], config.canned_responses.handle_missing_body.status)
  end

  local data = read_resource(body_data)
  local wrapped_data = {resource = data}

  -- check if a resource didn't exist before, and thus we need to return 201
  local res = db.select("fhir_read_resource(?);", to_json({resourceType = self.params.type, id = data.id}))
  local returned_resource = unpickle_fhirbase_result(res, "fhir_read_resource")
  local created_or_updated_response_code = returned_resource.resourceType == self.params.type and 200 or 201

  -- add a contention guard if there is one
  local if_match = ngx.req.get_headers()["If-Match-DryFHIR"]
  if if_match then
    wrapped_data.ifMatch = string.match(if_match, '^W/"(.+)"$')
  end

  -- perform the requested update on the resource
  res = db.select(operation.fhirbase_function .. "(?);", to_json(wrapped_data))

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

  return make_response(self, unpickle_fhirbase_result(res, operation.fhirbase_function), created_or_updated_response_code, {["Last-Modified"] = last_modified, ["ETag"] = etag, ["Location"] = location})
end

routes.delete_resource = function(self)
  local operation = {name = "delete", definition = "http://hl7.org/fhir/http.html#delete", fhirbase_function = "fhir_delete_resource"}

  local res = db.select(operation.fhirbase_function .. "(?);", to_json({resourceType = self.params.type, id = self.params.id}))

  local headers, http_status_code = {}, nil
  local resource = unpickle_fhirbase_result(res, operation.fhirbase_function)
  -- never existed: fhirbase returns 404, but it needs to return 204
  if resource.issue and resource.issue[1].extension[1].valueString == "404" then
    resource.issue[1].extension[1].valueString = "204"
    http_status_code = 204
  end
  -- existed but deleted already: need to return 200
  if resource.issue and resource.issue[1].extension[1].valueString == "410" then
    resource.issue[1].extension[1].valueString = "200"
    http_status_code = 200

    -- fish out the versionId of the deleted resource version for the ETag, so you can do
    -- version contention management when resource is re-created
    if ngx.shared.known_resources:get(self.params.type) then -- prevent people from passing dodgy resource names
      local resource_type = self.params.type:lower()
      local version_id = db.select(sformat("%s_history.version_id FROM public.%s_history WHERE %s_history.id = ? order by version_id desc limit 1", resource_type, resource_type, resource_type), self.params.id)
      headers["ETag"] = sformat('W/"%s"', version_id[1].version_id)
    end
  end
  -- just deleted: return 204
  if resource.resourceType == self.params.type then
    http_status_code = 204
    headers["ETag"] = sformat('W/"%s"', resource.meta.versionId)
  end

  return make_response(self, resource, http_status_code, headers)
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

  return make_response(self, bundle)
end

routes.search = function(self)
  local operation = {name = "search", definition = "http://hl7.org/fhir/http.html#search", fhirbase_function = "fhir_search"}

  local res = db.select(operation.fhirbase_function .. "(?);", to_json({resourceType = self.params.type, queryString = self.req.parsed_url.query}))

  local bundle = unpickle_fhirbase_result(res, operation.fhirbase_function)

  -- fill in the fullUrl fields in the Bundle response
  bundle = populate_bundle_fullUrls(self, bundle)

  return make_response(self, bundle)
end

routes.conditional_update_resource = function(self)
  local operation = {name = "conditional update", definition = "https://hl7-fhir.github.io/http.html#2.42.0.10.2", fhirbase_function = "fhir_update_resource"}

  ngx.req.read_body()
  local body_data = ngx.req.get_body_data()
  if not body_data then
    return make_response(self, config.canned_responses.handle_missing_body[1], config.canned_responses.handle_missing_body.status)
  end

  local data = read_resource(body_data)
  local wrapped_data = {resource = data}
  local http_status_code

  -- fhirbase conditional update is broken, so we do it ourselves (https://github.com/fhirbase/fhirbase-plv8/issues/81)
  local res = db.select("fhir_search(?);", to_json({resourceType = self.params.type, queryString = self.req.parsed_url.query}))
  local bundle = unpickle_fhirbase_result(res, "fhir_search")

  if bundle.total == 0 then
    operation.fhirbase_function = "fhir_create_resource"
    res = db.select(operation.fhirbase_function .. "(?);", to_json(wrapped_data))
    http_status_code = 201
  elseif bundle.total == 1 then
    local existing_resource_id = bundle.entry[1].resource.id
    wrapped_data.resource.id = existing_resource_id
    operation.fhirbase_function = "fhir_update_resource"
    res = db.select(operation.fhirbase_function .. "(?);", to_json(wrapped_data))
    http_status_code = 200
  else
    return make_response(self, config.canned_responses.conditinal_update_many_resources_exist[1], config.canned_responses.conditinal_update_many_resources_exist.status)
  end

  -- construct the appropriate Last-Modified, ETag, and Location headers
  local last_modified, etag, location
  local base_url = get_base_url(self)
  local resource = unpickle_fhirbase_result(res, operation.fhirbase_function)
  -- only do this for a resource that was created - ignore OperationOutcome resources
  if http_status_code ~= 412 and resource.meta then
    last_modified = date(resource.meta.lastUpdated):fmt("${http}")
    etag = sformat('W/"%s"', resource.meta.versionId)
    location = sformat("%s/%s/%s/_history/%s", base_url, resource.resourceType, resource.id, resource.meta.versionId)
  end

  return make_response(self, unpickle_fhirbase_result(res, operation.fhirbase_function), http_status_code, {["Last-Modified"] = last_modified, ["ETag"] = etag, ["Location"] = location})
end

routes.conditional_delete_resource = function(self)
  local operation = {name = "conditional delete", definition = "https://hl7-fhir.github.io/http.html#2.42.0.12.1", fhirbase_function = "fhir_update_resource"}

  local headers, http_status_code, resource = {}, nil, nil

  -- fhirbase lacks conditional delete, so we do it ourselves
  local res = db.select("fhir_search(?);", to_json({resourceType = self.params.type, queryString = sformat("%s&_count=%s", self.req.parsed_url.query, config.conditinal_delete_max_resouces)}))
  local bundle = unpickle_fhirbase_result(res, "fhir_search")

  -- get the actual query URL that was used by fhirbase for the search and sanitise it
  local used_query_url = get_value_by_key(bundle.link, "relation", "self", "url")[1]
  local remove_resource_type = sformat("/%s%%?", self.params.type)
  local remove_count_and_page = sformat("&_count=%s&_page=0", config.conditinal_delete_max_resouces)
  used_query_url = used_query_url:gsub(remove_resource_type, '')
  used_query_url = used_query_url:gsub(remove_count_and_page, '')

  if bundle.total == 0 then
    return make_response(self, config.canned_responses.conditional_delete_resource_missing[1], config.canned_responses.conditional_delete_resource_missing.status)
  elseif bundle.total == 1 then
    operation.fhirbase_function = "fhir_delete_resource"
    local resource_id_to_delete = bundle.entry[1].resource.id
    res = db.select(operation.fhirbase_function .. "(?);", to_json({resourceType = self.params.type, id = resource_id_to_delete}))
    http_status_code = 204
    resource = unpickle_fhirbase_result(res, operation.fhirbase_function)

    -- though it's not in the spec for conditional delete, a normal delete would like an ETag for resource
    -- contention, as does Touchstone - so we add it in
    if ngx.shared.known_resources:get(self.params.type) then -- prevent people from passing dodgy resource names
      local resource_type = self.params.type:lower()
      local version_id = db.select(sformat("%s_history.version_id FROM public.%s_history WHERE %s_history.id = ? order by version_id desc limit 1", resource_type, resource_type, resource_type), resource_id_to_delete)
      headers["ETag"] = sformat('W/"%s"', version_id[1].version_id)
    end
  else
    -- if we've enabled deleting multiple resources with conditional delete, allow the delete
    if config.fhir_multiple_conditional_delete then
      operation.fhirbase_function = "fhir_delete_resource"

      local successful_deletes = 0
      for i = 1, #bundle.entry do
        local matched_resource = bundle.entry[i].resource

        res = db.select(operation.fhirbase_function .. "(?);", to_json({resourceType = self.params.type, id = matched_resource.id}))
        local deleted_resource = unpickle_fhirbase_result(res, operation.fhirbase_function)
        if deleted_resource.resourceType == self.params.type then
          successful_deletes = successful_deletes + 1
        end
      end

      resource = populate_canned_response(config.canned_responses.conditional_delete_deleted_many[1], successful_deletes, self.params.type, used_query_url)
      http_status_code = config.canned_responses.conditional_delete_deleted_many.status
    else -- otherwise, disallow it
      http_status_code = 412
      resource = config.canned_responses.conditional_delete_multiple_disallowed[1]
    end
  end

  return make_response(self, resource, http_status_code, headers)
end

return routes
