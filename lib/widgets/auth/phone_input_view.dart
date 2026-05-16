import 'package:flutter/material.dart';
import 'package:intl_phone_field/intl_phone_field.dart';

class PhoneInputView extends StatelessWidget {
  final Function(String) onSubmitted;

  const PhoneInputView({super.key, required this.onSubmitted});

  @override
  Widget build(BuildContext context) {
    String phoneNumber = '';

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Enter your phone number',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
          ),
          const SizedBox(height: 12),
          Text(
            'Reel will send an SMS message to verify your phone number.',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Colors.white60,
                ),
          ),
          const SizedBox(height: 48),
          IntlPhoneField(
            decoration: const InputDecoration(
              labelText: 'Phone Number',
              hintText: '000 000 000',
            ),
            initialCountryCode: 'US',
            onChanged: (phone) {
              phoneNumber = phone.completeNumber;
            },
            style: const TextStyle(color: Colors.white),
            dropdownTextStyle: const TextStyle(color: Colors.white),
            cursorColor: Theme.of(context).primaryColor,
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                if (phoneNumber.isNotEmpty) {
                  onSubmitted(phoneNumber);
                }
              },
              child: const Text('Next'),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
