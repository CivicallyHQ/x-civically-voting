import { withPluginApi } from 'discourse/lib/plugin-api';
import Category from 'discourse/models/category';
import { ajax } from 'discourse/lib/ajax';
import RawHtml from 'discourse/widgets/raw-html';
import { popupAjaxError } from 'discourse/lib/ajax-error';
import showModal from 'discourse/lib/show-modal';
import { h } from 'virtual-dom';

export default {
  name: 'vote-edits',
  initialize() {
    withPluginApi('0.8.11', api => {

      api.reopenWidget('vote-box', {
        html(attrs, state){
          var voteCount = this.attach('vote-count', attrs);
          var voteButton = this.attach('vote-button', attrs);
          var voteOptions = this.attach('vote-options', attrs);
          let contents = [voteCount, voteButton, voteOptions];

          if (state.votesAlert > 0) {
            let text = "voting.votes_left";
            let textParams = {
              count: state.votesAlert,
              path: this.currentUser.get("path") + "/activity/votes",
            };

            if (attrs.category.has_vote_limit) {
              text = "voting.votes_left_category";
              textParams['categoryName'] = attrs.category.name;
            }

            const html = "<div class='voting-popup-menu vote-options popup-menu'>" + I18n.t(text, textParams) + "</div>";
            contents.push(new RawHtml({html}));
          }

          return contents;
        },

        addVote(){
          var topic = this.attrs;
          var state = this.state;
          return ajax("/voting/vote", {
            type: 'POST',
            data: {
              topic_id: topic.id
            }
          }).then(result => {
            this.updateTopic(result);
            this.updateCategory(result);
            this.updateUser(result);

            if (result.alert) {
              state.votesAlert = result.votes_left;
            }

            state.allowClick = true;
            this.scheduleRerender();
          }).catch(popupAjaxError);
        },

        removeVote(){
          const topic = this.attrs;
          const state = this.state;

          return ajax("/voting/unvote", {
            type: 'POST',
            data: {
              topic_id: topic.id
            }
          }).then(result => {
            this.updateTopic(result);
            this.updateCategory(result);
            this.updateUser(result);

            state.allowClick = true;
            this.scheduleRerender();
          }).catch(popupAjaxError);
        },

        updateCategory(result) {
          const categoryId = this.attrs.category_id;
          const category = Category.findById(categoryId);

          if (result.hasOwnProperty('category_votes_exceeded')) {
            category.set('votes_exceeded', result.category_votes_exceeded);
          }
        },

        updateTopic(result) {
          const topic = this.attrs;
          topic.set('vote_count', result.vote_count);
          topic.set('user_voted', result.user_voted);
          topic.set('who_voted', result.who_voted);
        },

        updateUser(result) {
          this.currentUser.set('votes_exceeded', result.user_votes_exceeded);
        }
      });

      api.reopenWidget('vote-button', {
        html(attrs){
          var buttonTitle = I18n.t('voting.vote_title');
          const user = this.currentUser;

          if (!user){
            buttonTitle = I18n.t('log_in');
          }
          else{
            if (attrs.closed){
              buttonTitle = I18n.t('voting.voting_closed_title');
            }
            else{
              if (attrs.user_voted){
                buttonTitle = I18n.t('voting.voted_title');
              }
              else{
                if (user && this.votesExceeded()){
                  buttonTitle = I18n.t(`voting.voting_limit`);
                }
                else{
                  buttonTitle = I18n.t('voting.vote_title');
                }
              }
            }
          }
          return buttonTitle;
        },

        click(){
          if (!this.currentUser){
            showModal('login');
          }

          const votesExceeded = this.votesExceeded();

          if (!this.attrs.closed && !votesExceeded && this.parentWidget.state.allowClick && !this.attrs.user_voted){
            this.parentWidget.state.allowClick = false;
            this.parentWidget.state.initialVote = true;
            this.sendWidgetAction('addVote');
          }

          if (this.attrs.user_voted || votesExceeded) {
            $(".vote-options").toggle();
          }
        },

        votesExceeded() {
          const category = this.attrs.category;
          const user = this.currentUser;
          return category.has_vote_limit ? category.votes_exceeded : user && user.votes_exceeded;
        }
      });

      api.reopenWidget('vote-options', {
        html(attrs){
          var contents = [];

          if (attrs.user_voted){
              contents.push(this.attach('remove-vote', attrs));
          }
          else if (this.currentUser && !attrs.user_voted && (attrs.category.votes_exceeded || this.currentUser.votes_exceeded)) {
            let text = I18n.t('voting.reached_limit');

            if (attrs.category.votes_exceeded) {
              text = I18n.t('voting.reached_category_limit', { categoryName: attrs.category.name });
            }

            contents.push([
                h("div", text),
                h("p",
                  h("a",{ href: this.currentUser.get("path") + "/activity/votes" }, I18n.t("voting.list_votes"))
                )
            ]);
          }
          return contents;
        }
      });
    });
  }
};
