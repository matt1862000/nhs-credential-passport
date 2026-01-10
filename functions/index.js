const { onDocumentUpdated } = require('firebase-functions/v2/firestore');
const { initializeApp } = require('firebase-admin/app');
const { getMessaging } = require('firebase-admin/messaging');

initializeApp();

exports.onClinicianDelayChange = onDocumentUpdated('clinicians/{clinicianId}', async (event) => {
  const before = event.data.before.data();
  const after = event.data.after.data();
  
  const oldDelay = before.delay || 0;
  const newDelay = after.delay || 0;
  
  if (oldDelay === newDelay) {
    console.log('No delay change, skipping notification');
    return null;
  }
  
  // Build full name with title to match app subscription format
  const clinicianTitle = after.title || '';
  const clinicianName = after.name || 'Unknown';
  const fullName = (clinicianTitle + ' ' + clinicianName).trim();
  const topic = 'clinician_' + fullName.replace(/[^a-zA-Z0-9]/g, '_');
  
  // Create short name for notification (e.g., "Dr. Thompson" instead of "Dr. James Thompson")
  const nameParts = clinicianName.split(' ');
  const surname = nameParts.length > 1 ? nameParts[nameParts.length - 1] : clinicianName;
  const shortName = clinicianTitle ? (clinicianTitle + ' ' + surname) : surname;
  
  let notifTitle, notifBody;
  
  if (newDelay > oldDelay) {
    const increase = newDelay - oldDelay;
    notifTitle = shortName + "'s Clinic";
    notifBody = 'Delay increased by ' + increase + ' min (now ' + newDelay + ' min). Thank you for your patience.';
  } else {
    const decrease = oldDelay - newDelay;
    if (newDelay === 0) {
      notifTitle = shortName + "'s Clinic";
      notifBody = 'The clinic is now running on time.';
    } else if (newDelay <= 5) {
      notifTitle = shortName + "'s Clinic";
      notifBody = 'Delay reduced to ' + newDelay + ' min. Thank you for waiting.';
    } else {
      notifTitle = shortName + "'s Clinic";
      notifBody = 'Delay reduced by ' + decrease + ' min (now ' + newDelay + ' min).';
    }
  }
  
  const message = {
    notification: {
      title: notifTitle,
      body: notifBody
    },
    // Custom data payload - accessible when user taps notification
    data: {
      topic: topic,
      clinicianName: fullName,
      newDelay: String(newDelay),
      oldDelay: String(oldDelay)
    },
    // iOS-specific: Enable actionable notification with buttons
    apns: {
      payload: {
        aps: {
          'category': 'DELAY_NOTIFICATION',  // Must match NotificationService.registerNotificationCategories()
          'mutable-content': 1,
          'sound': 'default'
        }
      }
    },
    topic: topic
  };
  
  console.log('Sending notification to topic: ' + topic + ' with category DELAY_NOTIFICATION');
  
  try {
    const response = await getMessaging().send(message);
    console.log('Successfully sent message:', response);
    return response;
  } catch (error) {
    console.error('Error sending message:', error);
    return null;
  }
});