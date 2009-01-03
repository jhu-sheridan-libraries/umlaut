# Needs to be called PrimoService to avoid conflicting with Primo module
# Params include:
# suppress_urls:      array of strings or regexps to NOT use from the catalog.
#                     Used for urls that duplicate SFX targets but which aren't
#                     caught by SfxUrl.sfx_controls_url. Regexps can be put
#                     in the services.yml like this:    
#                        [!ruby/regexp '/sagepub.com$/']
# suppress_holdings:  array of strings or regexps to NOT use from the catalog.
#                     Used for urls that duplicate SFX targets but which aren't
#                     caught by SfxUrl.sfx_controls_url. Regexps can be put
#                     in the services.yml like this:    
#                        [!ruby/regexp '/\$\$LWEB$/']
# status_map:         string representation of status mapping hash.
#                     Used for mapping status from Primo PNX record to user friendly
#                     text. 
#                     NOTE: Be careful of unescaped apostrophes (') in hash.  Encode as HTML -> &#39;
#                     Example:
#                        '{ "available" => "Available", "unavailable" => "Unavailable", "check_holdings" => "Check Holdings" }'
# library_map:        string representation of library mapping hash.
#                     Used for mapping library codes from Primo PNX record to user friendly
#                     text. 
#                     NOTE: Be careful of unescaped apostrophes (') in hash.  Encode as HTML -> &#39;
#                     Example:
#                        '{ "MYLIB" => "My Friendly Library", "YOURLIB" => "Your Friendly Library", "SCOTLIB" => "Scot&#39;s Library" }'
# ez_proxy:           string or regexp of an ezproxy prefix. 
#                     Used in the case where an ezproxy prefix (on any other regexp) is hardcoded in the URL,
#                     and needs to be removed ino order to match against SFXUrls.
#                     Example:
#                        !ruby/regexp '/https\:\/\/ezproxy\.library\.nyu\.edu\/login\?url=/'
# Code copied from J. Rochkind HIP3Service
#   A holdings service could be abstracted out and extended for particular implementations

class PrimoService < Service
  required_config_params :base_path, :display_name, :base_view_id
  attr_reader :base_path

  def initialize(config)
    # defaults
    @suppress_urls = []
    @suppress_holdings = []
    super(config)

    # Trim question-mark from base_url, if given
    @base_path.chop! if (@base_path.rindex('?') ==  @base_path.length)     
  end

  # Standard method, used by background service updater. See Service docs. 
  def service_types_generated
    # We generate full text and holdings types, right now.
    #types = [ ServiceTypeValue[:fulltext], ServiceTypeValue[:holding], ServiceTypeValue[:table_of_contents] ]
    types = [ ServiceTypeValue[:fulltext], ServiceTypeValue[:holding] ]
    
    return types
  end
  
  def handle(request)
    # Extend OpenURL standard to take Primo Doc Id
    # Necessary for Primo Referrer
    primo_id = request.referent.metadata['primo']

    # Standard numbers
    issn = request.referent.metadata['issn']
    isbn = request.referent.metadata['isbn']
      
    # TODO: Implement title, author, genre search if ID/SNs don't exist.
    title = request.referent.metadata['title']
    author = request.referent.metadata['au']
    genre = request.referent.metadata['genre']
    
    # Generic Primo Searcher.
    primo_searcher = Exlibris::Primo::PrimoSearcher.new(@base_path, @base_view_id)
    
    # Set Primo Searcher instance vars
    primo_searcher.primo_id = primo_id
    # don't send mal-formed issn
    primo_searcher.issn = issn if issn =~ /\d{4}(-)?\d{3}(\d|X)/ 
    primo_searcher.isbn = isbn 
    primo_searcher.title = title 
    primo_searcher.author = author 
    primo_searcher.genre = genre 

    # Get URLs from Primo Searcher (executes search)
    urls = primo_searcher.urls # Array of Exlibris::Primo::PrimoURLs

    # Let's find any URLs, and add full text responses for those.
    urls_seen = Array.new # for de-duplicating urls from catalog.
    urls.each do |primo_url|
      url = primo_url.url # actual url

      next if urls_seen.include?(url)
      # Don't add the URL if it matches our SFXUrl finder, because
      # that means we think this is an SFX controlled URL.
      # Handle EZProxy if hardcoded.
      next if SfxUrl.sfx_controls_url?(handle_ezproxy(url))
      # We have our own list of URLs to suppress, array of strings
      # or regexps.
      next if @suppress_urls.find {|suppress| suppress === url}
      
      # No url? Forget it.
      next if url.nil?
      
      urls_seen.push(url)
      
      display_name = primo_url.display # URL display name, based on Primo Normalization Rules 
      display_name = url if display_name.nil? # set display name to URL if no other display name
      
      value_text = Hash.new

      value_text[:url] = url

      value_text[:notes] = primo_url.notes
      if ( value_text[:notes].blank?) 
        # TODO: Update for coverage, could be based on Primo Normalization Rules
        #value_text[:notes] += "Dates of coverage unknown."
      end

      response_params = {:service=>self, :display_text=>display_name, :url=>url, :notes=>value_text[:notes], :service_data=>value_text}
      
      # Add the response
      request.add_service_response(response_params, ['fulltext_title_level'])
    end

    # Get holdings from Primo Searcher
    holdings = primo_searcher.holdings # Array of Exlibris::Primo::PrimoHoldings
    #Okay, we actually want to make each _copy_ into a service response.
    #A bib may have multiple copies. We are merging bibs, and just worrying
    #about the aggregated list of copies.
    holdings.each do |holding|
      url = holding.url
      # Probably won't match anything, but if reconfigured to point to src could be useful
      next if urls_seen.include?(url)
      # Probably won't match anything, but if reconfigured to point to src could be useful
      # Don't add the Holding if it matches our SFXUrl finder, because
      # that means we think this is an SFX controlled URL.
      next if SfxUrl.sfx_controls_url?(url)
      # We have our own list of Holdings to suppress, array of strings
      # or regexps.
      next if @suppress_holdings.find {|suppress| suppress === holding.raw}
      service_data = {}
      service_data[:call_number] = holding.call_number
      status = map_status(holding.status)
      service_data[:status] = status
      library = map_library(holding.library)
      id_one = holding.id_one
      collection_str = library# + id_one
      service_data[:collection_str] = collection_str
      service_data[:notes] = holding.notes
      service_data[:url] = url
      service_data[:display_text] = holding.text
      
      request.add_service_response( {:service=>self, :display_text => service_data[:display_text], :notes=>service_data[:notes], :url=> service_data[:url], :service_data=>service_data }, ['holding']  )

    end
    return request.dispatched(self, true)
  end
  
  private
  # If an ezproxy prefix (on any other regexp) is hardcoded in the URL,
  # strip it out for matching against SFXUrls
  def handle_ezproxy(str)
    return str if @ez_proxy.nil?
    return (str.gsub(@ez_proxy, '').nil? ? str : str.gsub(@ez_proxy, ''))
  end

  # map statuses to user friendly text,
  # loaded from services.yml 
  def map_status(str)
    h = eval @status_map unless @status_map.nil?
    map(str, h)
  end

  # map libraries to user friendly text,
  # loaded from services.yml 
  def map_library(str)
    h = eval @library_map unless @library_map.nil?
    map(str, h)
  end

  def map(str, h=nil)
    return str if (h.nil? or !h.kind_of? Hash)
    return (h[str].nil? ? str : h[str])
  end
end