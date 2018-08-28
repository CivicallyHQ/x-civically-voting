# name: civically-voting-extension
# about: Extends the voting plugin to have category specific limits
# version: 0.1
# authors: Angus McLeod
# url: https://github.com/civicallyhq/x-civically-voting

register_asset 'stylesheets/common/voting-extension.scss'
register_asset 'stylesheets/mobile/voting-extension.scss', :mobile

after_initialize do
  Category.register_custom_field_type('apply_site_vote_limits', :boolean)
  Category.register_custom_field_type('tl0_vote_limit', :integer)
  Category.register_custom_field_type('tl1_vote_limit', :integer)
  Category.register_custom_field_type('tl2_vote_limit', :integer)
  Category.register_custom_field_type('tl3_vote_limit', :integer)
  Category.register_custom_field_type('tl4_vote_limit', :integer)

  require_dependency 'basic_category_serializer'
  class ::BasicCategorySerializer
    attributes :has_vote_limit, :votes_exceeded, :site_vote_limits

    def has_vote_limit
      scope && scope.user && scope.user.has_category_limit?(object.id)
    end

    def votes_exceeded
      scope.user.reached_category_voting_limit?(object.id)
    end

    def include_votes_exceeded?
      has_vote_limit
    end

    def site_vote_limits
      object.site_vote_limits
    end
  end

  class ::Category
    def site_vote_limits
      self.custom_fields['site_vote_limits']
    end
  end

  class ::Topic
    def can_vote?
      SiteSetting.voting_enabled &&
      (Category.can_vote?(category_id) || subtype === 'petition' || subtype === 'content') &&
      category.topic_id != id
    end
  end

  ::User.class_eval do
    def vote_count(category_id = nil)
      user_votes = category_id ? category_votes(category_id) : votes

      if user_votes
        user_votes.length
      else
        0
      end
    end

    def alert_low_votes?
      (vote_limit - vote_count) <= SiteSetting.voting_alert_votes_left
    end

    def votes
      [*self.custom_fields["votes"]]
    end

    def category_votes(category_id)
      [*self.custom_fields["#{category_id}_votes"]]
    end

    def votes_archive
      [*self.custom_fields["votes_archive"]]
    end

    def reached_voting_limit?
      vote_count >= vote_limit
    end

    def vote_limit
      SiteSetting.send("voting_tl#{self.trust_level}_vote_limit")
    end

    def category_vote_limit(category_id = nil)
      return nil if !category_id
      category = Category.find(category_id)
      category_limit = category.custom_fields["tl#{self.trust_level}_vote_limit"]

      if category_limit
        if category.custom_fields["apply_site_vote_limits"]
          [category_limit, vote_limit].min
        else
          category_limit
        end
      else
        nil
      end
    end

    def has_category_limit?(category_id)
      CategoryCustomField.exists?(name: "tl#{self.trust_level}_vote_limit", category_id: category_id)
    end

    def reached_category_voting_limit?(category_id)
      vote_count(category_id) >= category_vote_limit(category_id)
    end

    def add_vote(topic)
      self.custom_fields["votes"] = votes.dup.push(topic.id)
      self.custom_fields["#{topic.category.id}_votes"] = category_votes(topic.category.id).dup.push(topic.id)
      DiscourseEvent.trigger(:vote_added, self, topic)
    end

    def remove_vote(topic)
      self.custom_fields["votes"] = votes.dup - [topic.id.to_s]
      self.custom_fields["#{topic.category.id}_votes"] = category_votes(topic.category.id).dup - [topic.id.to_s]
      DiscourseEvent.trigger(:vote_removed, self, topic)
    end

    def remove_archived_vote(topic)
      self.custom_fields["votes_archive"] = votes_archive.dup.push(topic.id)
    end

    def add_archived_vote(topic)
      self.custom_fields["votes_archive"] = votes_archive.dup - [topic.id.to_s]
    end
  end

  if defined?(DiscourseVoting) == 'constant' && DiscourseVoting.class == Module
    class DiscourseVoting::VotesController
      def add
        topic = Topic.find_by(id: params["topic_id"])

        raise Discourse::InvalidAccess if !topic.can_vote?
        guardian.ensure_can_see!(topic)

        user = current_user
        voted = false
        has_category_limit = user.has_category_limit?(topic.category_id)
        reached_site_limit = user.reached_voting_limit?
        reached_category_limit = user.reached_category_voting_limit?(topic.category_id) if has_category_limit
        reached_applicable_limit = has_category_limit ? reached_category_limit : reached_site_limit

        unless reached_applicable_limit
          user.add_vote(topic)
          user.save
          update_vote_count(topic)
          voted = true
        end

        vote_limit = has_category_limit ? user.category_vote_limit(topic.category_id) : user.vote_limit
        user_vote_count = user.vote_count(topic.category_id)

        obj = {
          user_votes_exceeded: reached_site_limit,
          user_voted: true,
          vote_limit: vote_limit,
          vote_count: topic.custom_fields["vote_count"].to_i,
          who_voted: who_voted(topic),
          alert: user.alert_low_votes?,
          votes_left: [(vote_limit - user_vote_count), 0].max
        }

        if has_category_limit
          obj[:category_votes_exceeded] = reached_category_limit
        end

        render json: obj, status: voted ? 200 : 403
      end

      def remove
        topic = Topic.find_by(id: params["topic_id"])

        guardian.ensure_can_see!(topic)

        user = current_user
        user.remove_vote(topic)
        user.save

        update_vote_count(topic)

        vote_limit = user.has_category_limit?(topic.category_id) ?
                     user.category_vote_limit(topic.category_id) :
                     user.vote_limit
        obj = {
          user_votes_exceeded: user.reached_voting_limit?,
          user_voted: false,
          vote_limit: vote_limit,
          vote_count: topic.custom_fields["vote_count"].to_i,
          who_voted: who_voted(topic),
          votes_left: [(vote_limit - user.vote_count(topic.category_id)), 0].max
        }

        if user.has_category_limit?(topic.category_id)
          obj[:category_votes_exceeded] = user.reached_category_voting_limit?(topic.category_id)
        end

        render json: obj
      end
    end
  end
end
