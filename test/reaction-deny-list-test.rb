# frozen_string_literal: true
abort "Disposable database only" unless ENV["RIVER_DISPOSABLE"] == "1" &&
  GlobalSetting.db_name == "river_reaction_security_test"
require "minitest/autorun"
require "rack/mock"

class ReactionDenyListTest < Minitest::Test
  R = DiscourseReactions
  H = R::ReactionsSerializerHelpers

  def setup
    SiteSetting.discourse_reactions_enabled = true
    SiteSetting.discourse_reactions_allow_any_emoji = true
    SiteSetting.discourse_reactions_reaction_for_like = "heart"
    SiteSetting.discourse_reactions_excluded_from_like = "-1"
    SiteSetting.emoji_deny_list = ""
    SiteSetting.chat_enabled = true
    SiteSetting.chat_allowed_groups = Group::AUTO_GROUPS[:everyone].to_s
    SiteSetting.min_personal_message_post_length = 1
    SiteSetting.min_post_length = 1
    @author = user("author", admin: true)
    @user = user("reactor")
    @other = user("other")
    @category = Category.find_by(id: SiteSetting.uncategorized_category_id)
    @post = PostCreator.create!(@author, title: "Reaction policy #{SecureRandom.hex(5)}", raw: "A synthetic post used only in an isolated database.", category: @category.id, skip_validations: true)
    @guardian = Guardian.new(@user)
  end

  def user(prefix, admin: false)
    name = "#{prefix}_#{SecureRandom.hex(4)}"
    User.create!(username: name, email: "#{name}@example.com", password: SecureRandom.hex(24), active: true, approved: true, trust_level: 2, admin: admin)
  end

  def deny(value)
    SiteSetting.emoji_deny_list = value
  end

  def toggle(value, who = @user)
    R::ReactionManager.new(reaction_value: value, user: who, post: @post.reload).toggle!
  end

  def request(method, path, params = {}, who: @user)
    key = ApiKey.create!(user_id: who.id, created_by_id: @author.id, description: "isolated reaction policy test")
    Rack::MockRequest.new(Rails.application).request(method, "https://reaction.test#{path}",
      "HTTP_HOST" => "reaction.test", "HTTPS" => "on", "HTTP_API_KEY" => key.key,
      "HTTP_API_USERNAME" => who.username, "CONTENT_TYPE" => "application/json",
      input: method == "GET" ? nil : params.to_json)
  end

  def test_existence_is_unchanged_but_denied_spelling_variants_are_rejected
    deny("taiwan|+1")
    %w[taiwan :taiwan: taiwan: :taiwan +1 thumbsup :thumbsup: +1:t2 :thumbsup:t3:].each do |code|
      refute Emoji.reaction_allowed?(code), code
    end
    assert Emoji.exists?("taiwan")
    assert Emoji.exists?("thumbsup")
    assert Emoji.reaction_allowed?("laughing")
    [nil, "", "not_a_real_emoji", 4].each { |v| refute Emoji.reaction_allowed?(v) }
  end

  def test_alias_in_deny_list_blocks_canonical_and_cache_changes_immediately
    deny("thumbsup")
    refute Emoji.reaction_allowed?("+1")
    deny("")
    assert Emoji.reaction_allowed?("+1")
    deny("taiwan")
    refute Emoji.reaction_allowed?("taiwan")
  end

  def test_tone_specific_denial_does_not_block_other_tones
    deny("+1:t2")
    refute Emoji.reaction_allowed?("thumbsup:t2")
    assert Emoji.reaction_allowed?("+1:t3")
    assert Emoji.reaction_allowed?("+1")
  end

  def test_custom_emoji_is_subject_to_the_same_rule
    Plugin::CustomEmoji.register("rs_test_custom", "/test.png", "test")
    Emoji.clear_cache
    assert Emoji.reaction_allowed?("rs_test_custom")
    deny("rs_test_custom")
    refute Emoji.reaction_allowed?(":rs_test_custom:")
  ensure
    Emoji.clear_cache
  end

  def test_denied_reaction_rejected_in_both_picker_modes_and_display_modes
    SiteSetting.discourse_reactions_enabled_reactions = "taiwan|laughing|+1"
    deny("taiwan")
    [true, false].each do |any|
      SiteSetting.discourse_reactions_allow_any_emoji = any
      [true, false].each do |display|
        SiteSetting.discourse_reactions_show_individual_counts = display
        refute R::Reaction.valid?("taiwan")
        assert R::Reaction.valid?("laughing")
        result = request("PUT", "/discourse-reactions/posts/#{@post.id}/custom-reactions/taiwan/toggle.json")
        assert_includes [400, 403, 422], result.status, result.body
        assert_equal 0, @post.reactions.count
      end
    end
  end

  def test_denied_attempt_does_not_replace_an_existing_allowed_reaction
    toggle("laughing")
    deny("taiwan")
    assert_raises(Discourse::InvalidAccess) { toggle("taiwan") }
    assert_equal "laughing", @post.reload.reactions.first.reaction_value
    assert_equal 1, R::ReactionUser.where(post: @post, user: @user).count
  end

  def test_model_create_and_update_cannot_bypass_the_policy
    deny("taiwan")
    assert_raises(ActiveRecord::RecordInvalid) { R::Reaction.create!(post: @post, reaction_value: "taiwan", reaction_type: :emoji) }
    reaction = R::Reaction.create!(post: @post, reaction_value: "laughing", reaction_type: :emoji)
    assert_raises(ActiveRecord::RecordInvalid) { reaction.update!(reaction_value: "taiwan") }
  end

  def test_old_denied_reaction_is_hidden_but_can_be_undone_only_once
    toggle("taiwan")
    deny("taiwan")
    p = Post.find(@post.id)
    assert_empty H.reactions_for_post(p, @guardian)
    assert_nil H.current_user_reaction_for_post(p, @guardian)
    assert_equal 0, H.reaction_users_count_for_post(p, @guardian)
    H.preload_post_reactions([p], @user)
    assert_empty H.reactions_for_post(p, @guardian)
    assert_equal 0, H.reaction_users_count_for_post(p, @guardian)
    json = PostSerializer.new(p, scope: @guardian, root: false).as_json.to_json
    refute_includes json, '"taiwan"'
    response = request("PUT", "/discourse-reactions/posts/#{p.id}/custom-reactions/taiwan/toggle.json")
    assert_equal 200, response.status, response.body
    assert_equal 0, R::ReactionUser.where(post: p, user: @user).count
    response = request("PUT", "/discourse-reactions/posts/#{p.id}/custom-reactions/taiwan/toggle.json")
    assert_includes [400, 403, 422], response.status
  end

  def test_post_read_apis_and_pagination_hide_denied_reactions
    toggle("taiwan")
    toggle("laughing", @other)
    deny("taiwan")
    rows, total = R::PostReactionsQuery.call(post: @post, limit: 1)
    assert_equal 1, total
    assert_equal ["laughing"], rows.map(&:reaction)
    rows, total = R::PostReactionsQuery.call(post: @post, reaction_filter: "taiwan")
    assert_empty rows
    assert_equal 0, total
    ["/posts/#{@post.id}/reactions-users.json", "/posts/#{@post.id}/reactions-users-list.json",
     "/posts/reactions.json?username=#{@user.username}", "/posts/reactions-received.json?username=#{@author.username}"].each do |path|
      response = request("GET", "/discourse-reactions#{path}", {}, who: @author)
      assert_equal 200, response.status, response.body
      refute_includes response.body, '"taiwan"'
    end
    response = request("GET", "/t/#{@post.topic_id}.json")
    assert_equal 200, response.status, response.body
    refute_includes response.body, '"taiwan"'
  end

  def test_historical_colon_spelling_is_hidden_and_unbanning_restores_history
    toggle(":taiwan:")
    deny("taiwan")
    rows, total = R::PostReactionsQuery.call(post: @post)
    assert_empty rows
    assert_equal 0, total
    assert_empty H.reactions_for_post(Post.find(@post.id), @guardian)
    assert_equal 1, R::ReactionUser.where(post: @post).count
    deny("")
    assert_equal [":taiwan:"], H.reactions_for_post(Post.find(@post.id), @guardian).map { |r| r[:id] }
  end

  def test_denied_main_reaction_does_not_leak_through_plain_likes
    toggle("heart")
    deny("heart")
    assert_empty H.reactions_for_post(@post.reload, @guardian)
    assert_nil H.current_user_reaction_for_post(@post, @guardian)
    rows, total = R::PostReactionsQuery.call(post: @post)
    assert_empty rows
    assert_equal 0, total
    response = request("PUT", "/discourse-reactions/posts/#{@post.id}/custom-reactions/heart/toggle.json")
    assert_equal 200, response.status, response.body
  end

  def test_allowed_reaction_round_trip_still_works
    deny("taiwan")
    path = "/discourse-reactions/posts/#{@post.id}/custom-reactions/laughing/toggle.json"
    response = request("PUT", path)
    assert_equal 200, response.status, response.body
    assert_equal ["laughing"], H.reactions_for_post(@post.reload, @guardian).map { |r| r[:id] }
    response = request("PUT", path)
    assert_equal 200, response.status, response.body
    assert_empty JSON.parse(response.body)["reactions"]
    assert_empty H.reactions_for_post(Post.find(@post.id), @guardian)
  end

  def chat
    channel = Chat::CategoryChannel.create!(chatable: @category, name: "Test #{SecureRandom.hex(5)}")
    channel.add(@user)
    message = Chat::Message.create!(chat_channel: channel, user: @author, message: "Synthetic chat message")
    [channel, message, Chat::MessageReactor.new(@user, channel)]
  end

  def test_chat_blocks_shortcode_alias_unicode_and_direct_model_writes
    channel, message, reactor = chat
    deny("taiwan|+1")
    ["taiwan", ":taiwan:", "🇹🇼", "thumbsup", "👍", "+1:t2"].each do |emoji|
      assert_raises(Discourse::InvalidParameters) { reactor.react!(message_id: message.id, react_action: :add, emoji: emoji) }
    end
    assert_raises(ActiveRecord::RecordInvalid) { Chat::MessageReaction.create!(chat_message: message, user: @user, emoji: "taiwan") }
    response = request("PUT", "/chat/#{channel.id}/react/#{message.id}.json", {emoji: "taiwan", react_action: "add"})
    assert_includes [400, 403, 422], response.status, response.body
    assert_equal 0, message.reactions.count
  end

  def test_chat_hides_historical_data_and_allows_removal
    channel, message, reactor = chat
    reactor.react!(message_id: message.id, react_action: :add, emoji: "taiwan")
    reactor.react!(message_id: message.id, react_action: :add, emoji: "laughing")
    deny("taiwan")
    data = Chat::MessageSerializer.new(message.reload, scope: @guardian, root: false).as_json
    assert_equal ["laughing"], data[:reactions].map { |r| r[:emoji] }
    rows, total = Chat::MessageReactionUsersQuery.call(message: message, limit: 1)
    assert_equal 1, total
    assert_equal ["laughing"], rows.map(&:reaction)
    rows, total = Chat::MessageReactionUsersQuery.call(message: message, emoji: "taiwan")
    assert_empty rows
    assert_equal 0, total
    response = request("GET", "/chat/#{channel.id}/#{message.id}/reactions-users.json")
    assert_equal 200, response.status, response.body
    refute_includes response.body, '"taiwan"'
    reactor.react!(message_id: message.id, react_action: :remove, emoji: "taiwan")
    assert_equal ["laughing"], message.reactions.reload.pluck(:emoji)
    assert_raises(Discourse::InvalidParameters) { reactor.react!(message_id: message.id, react_action: :add, emoji: "taiwan") }
  end
end
