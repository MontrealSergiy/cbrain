
#
# CBRAIN Project
#
# Copyright (C) 2008-2020
# The Royal Institution for the Advancement of Learning
# McGill University
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

# A stupid class to provide methods to cache
# the browsing results of a data provider into
class BrowseProviderFileCaching

  Revision_info = CbrainFileRevision[__FILE__] #:nodoc:

  # How long we cache the results of provider_list_all();
  BROWSE_CACHE_EXPIRATION = 60.seconds #:nodoc:
  RACE_CONDITION_DELAY    = 10.seconds # Short delay for concurrent threads

  # Contacts the +provider+ side with provider_list_all(as_user) and
  # caches the resulting array of FileInfo objects for 60 seconds.
  # Returns that array. If refresh is set to true, it will force the
  # refresh of the array, otherwise any array that was generated less
  # than 60 seconds ago is returned again.
  def self.get_recent_provider_list_all(provider, as_user = current_user, refresh = false) #:nodoc:

    refresh = false if refresh.blank? || refresh.to_s == 'false'

    Rails.cache.fetch(dp_cache_key(as_user, provider), force: refresh, expires_in: BROWSE_CACHE_EXPIRATION, race_condition_ttl: RACE_CONDITION_DELAY) do
      provider.provider_list_all(as_user)
    end
  end

  # Clear the cache file.
  def self.clear_cache(user, provider) #:nodoc:
    Rails.cache.delete(dp_cache_key(user, provider))
  end

  private

  def self.dp_cache_key(user, provider)
    "dp_file_list_#{user.try(:id)}_#{provider.try(:id)}"
  end

end

