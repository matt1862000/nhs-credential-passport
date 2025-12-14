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
  
  const clinicianName = after.name || 'Unknown';
  const topic = 'clinician_' + clinicianName.replace(/[^a-zA-Z0-9]/g, '_');
  
  let title, body;
  
  if (newDelay > oldDelay) {
    const increase = newDelay - oldDelay;
    title = 'Clinic Delay Updated ⏰';
    body = 'The clinic delay has increased by ' + increase + ' minutes (now ' + newDelay + ' min delay). We apologise for any inconvenience.';
  } else {
    const decrease = oldDelay - newDelay;
    if (newDelay === 0) {
      title = 'Good News! 🎉';
      body = 'The clinic is now running on time.';
    } else if (newDelay <= 5) {
      title = 'Good News! 🎉';
      body = 'The clinic delay has reduced to just ' + newDelay + ' minutes.';
    } else {
      title = 'Good News! 🎉';
      body = 'The clinic delay has reduced by ' + decrease + ' minutes (now ' + newDelay + ' min delay).';
    }
  }
  
  const message = {
    notification: {
      title: title,
      body: body
    },
    topic: topic
  };
  
  console.log('Sending notification to topic: ' + topic);
  
  try {
    const response = await getMessaging().send(message);
    console.log('Successfully sent message:', response);
    return response;
  } catch (error) {
    console.error('Error sending message:', error);
    return null;
  }
});